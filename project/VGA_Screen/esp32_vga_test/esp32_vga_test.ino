// ESP32 VGA 測試 - 沒有 FPGA 板時, 用 ESP32 送出 640x480@60Hz 測試畫面,
//   先驗證 DB15 轉接頭 + 4 bit 電阻 DAC + 螢幕這段硬體
// 開發板選 "ESP32 Dev Module" (Arduino-ESP32 core 3.x)
//   只有原版 ESP32 的 I2S 有 LCD 並列輸出模式, C3/C6 不能用
// 電阻和 FPGA 版同一組 (3.3 V bank): bit3 = 510 Ω, bit2 = 1 kΩ, bit1 = 2 kΩ, bit0 = 3.9 kΩ, HS/VS = 100 Ω
//   同色 4 顆電阻的另一端並接到 DB15 同一支腳 (R = 1, G = 2, B = 3, HS = 13, VS = 14)
//   ESP32 的 GND 要接 DB15 的 5/6/7/8/10
// 序列埠 115200: 每秒印出從 VS 腳讀回的脈衝數, 60 代表像素時脈設定正確

#include "soc/i2s_struct.h"
#include "soc/gpio_sig_map.h"
#include "esp_private/periph_ctrl.h"
#include "clk_ctrl_os.h"
#include "esp_rom_gpio.h"
#include "driver/gpio.h"

// 排針由左到右剛好是 bit3 -> bit0
const uint8_t R_PINS[4] = {14, 27, 26, 25};  // 上排
const uint8_t G_PINS[4] = {17, 5, 18, 19};   // 下排
const uint8_t B_PINS[4] = {4, 21, 22, 23};   // 下排
const uint8_t HS_PIN    = 33;                // 上排
const uint8_t VS_PIN    = 32;                // 上排
// 沒用到的腳: 0/2/12/15 是開機 strap 腳 (例如 0 被 DAC 經螢幕的 75 Ω 拉低就會進燒錄模式),
//   1/3 是 USB 序列埠, 6~11 接內部 flash, 16 接板上 RGB LED, 34~39 只能輸入

// 640x480@60 的標準時序, 但每個 sample 佔 2 個像素: 像素時脈減半成 12.5875 MHz, 螢幕看到的 HS/VS 完全一樣
//   測試圖案用不到 640 的水平解析度, 減半後 16 bit DMA 只要 25 MB/s, 比較穩
const uint32_t SAMPLE_HZ = 12587500;
const int H_VISIBLE = 320, H_FRONT = 8,  H_SYNC = 48, H_BACK = 24;
const int V_VISIBLE = 480, V_FRONT = 10, V_SYNC = 2,  V_BACK = 33;
const int H_TOTAL = H_VISIBLE + H_FRONT + H_SYNC + H_BACK;
const int V_TOTAL = V_VISIBLE + V_FRONT + V_SYNC + V_BACK;

// sample 格式: [3:0] R, [7:4] G, [11:8] B, [12] HS, [13] VS
const uint16_t HS_BIT = 1 << 12;
const uint16_t VS_BIT = 1 << 13;

static constexpr uint16_t rgb(int r, int g, int b) { return r | (g << 4) | (b << 8); }
const uint16_t WHITE = rgb(15, 15, 15);

enum LineType { L_BLANK, L_VSYNC, L_WHITE, L_BARS, L_RAMP_R, L_RAMP_G, L_RAMP_B, L_RAMP_GRAY, L_COUNT };

// 不能加 const: const 會放進 flash, DMA 讀不到
alignas(4) static uint16_t lines[L_COUNT][H_TOTAL];

// DMA 硬體規定的描述子格式, 和 IDF 的 lldesc_t 相同
struct DmaDesc {
    uint32_t size : 12, length : 12, offset : 5, sosf : 1, eof : 1, owner : 1;
    const void *buf;
    DmaDesc *next;
};
// 每條掃描線一個描述子, 頭尾相接成環, DMA 會一直重播整張畫面, 完全不用 CPU
static DmaDesc desc[V_TOTAL];

static volatile uint32_t vsCount = 0;

static void fillLine(uint16_t *line, uint16_t (*pixel)(int x), bool vsync)
{
    for (int x = 0; x < H_TOTAL; x++) {
        // 遮沒期間 RGB 一定要是 0: 螢幕會拿這段的電壓當黑色基準
        uint16_t v = 0;
        if (pixel && x < H_VISIBLE)
            // 左右各 2 個 sample 白邊, 讓螢幕的自動調整抓得到畫面寬度
            v = (x < 2 || x >= H_VISIBLE - 2) ? WHITE : pixel(x);
        bool hsPulse = x >= H_VISIBLE + H_FRONT && x < H_VISIBLE + H_FRONT + H_SYNC;
        // 640x480 的 HS/VS 都是負脈衝
        if (!hsPulse) v |= HS_BIT;
        if (!vsync)   v |= VS_BIT;
        // I2S 16 bit 模式每 32 bit 裡的 2 個 sample 會對調送出 (bitluni ESP32Lib 也是寫 x ^ 1)
        line[x ^ 1] = v;
    }
}

static uint16_t white(int) { return WHITE; }

static uint16_t colorBar(int x)
{
    static const uint16_t BARS[8] = { rgb(15, 15, 15), rgb(15, 15, 0), rgb(0, 15, 15), rgb(0, 15, 0),
                                      rgb(15, 0, 15),  rgb(15, 0, 0),  rgb(0, 0, 15),  rgb(0, 0, 0) };
    return BARS[x * 8 / H_VISIBLE];
}

static uint16_t rampR(int x)    { int l = x * 16 / H_VISIBLE; return rgb(l, 0, 0); }
static uint16_t rampG(int x)    { int l = x * 16 / H_VISIBLE; return rgb(0, l, 0); }
static uint16_t rampB(int x)    { int l = x * 16 / H_VISIBLE; return rgb(0, 0, l); }
static uint16_t rampGray(int x) { int l = x * 16 / H_VISIBLE; return rgb(l, l, l); }

static void buildFrame()
{
    fillLine(lines[L_BLANK],     nullptr,  false);
    fillLine(lines[L_VSYNC],     nullptr,  true);
    fillLine(lines[L_WHITE],     white,    false);
    fillLine(lines[L_BARS],      colorBar, false);
    fillLine(lines[L_RAMP_R],    rampR,    false);
    fillLine(lines[L_RAMP_G],    rampG,    false);
    fillLine(lines[L_RAMP_B],    rampB,    false);
    fillLine(lines[L_RAMP_GRAY], rampGray, false);

    // 由上到下 5 個色帶; 第一條和最後一條可見線全白, 當上下邊框
    static const LineType BANDS[5] = { L_BARS, L_RAMP_R, L_RAMP_G, L_RAMP_B, L_RAMP_GRAY };
    for (int y = 0; y < V_TOTAL; y++) {
        LineType t = L_BLANK;
        if (y == 0 || y == V_VISIBLE - 1)
            t = L_WHITE;
        else if (y < V_VISIBLE)
            t = BANDS[y * 5 / V_VISIBLE];
        else if (y >= V_VISIBLE + V_FRONT && y < V_VISIBLE + V_FRONT + V_SYNC)
            t = L_VSYNC;

        desc[y].size   = sizeof(lines[t]);
        desc[y].length = sizeof(lines[t]);
        desc[y].owner  = 1;
        desc[y].buf    = lines[t];
        desc[y].next   = &desc[(y + 1) % V_TOTAL];
    }
}

static void routePin(uint8_t pin, int sampleBit)
{
    esp_rom_gpio_pad_select_gpio(pin);
    // gpio_set_direction 會把腳接回一般 GPIO 輸出, 所以要先設方向再接 I2S
    // 順便開輸入, VS 才讀得回來量頻率
    gpio_set_direction((gpio_num_t)pin, GPIO_MODE_INPUT_OUTPUT);
    // I2S1 的 16 bit 並列資料在 OUT8 ~ OUT23
    esp_rom_gpio_connect_out_signal(pin, I2S1O_DATA_OUT8_IDX + sampleBit, false, false);
}

static uint32_t startI2S()
{
    periph_module_enable(PERIPH_I2S1_MODULE);

    I2S1.conf.val = 0;
    I2S1.conf.tx_reset = 1;
    I2S1.conf.tx_reset = 0;
    I2S1.conf.tx_fifo_reset = 1;
    I2S1.conf.tx_fifo_reset = 0;
    I2S1.lc_conf.out_rst = 1;
    I2S1.lc_conf.out_rst = 0;
    I2S1.lc_conf.ahbm_rst = 1;
    I2S1.lc_conf.ahbm_rst = 0;
    I2S1.lc_conf.ahbm_fifo_rst = 1;
    I2S1.lc_conf.ahbm_fifo_rst = 0;

    // LCD 模式 = 並列輸出, 暫存器組合照 bitluni ESP32Lib 的 16 bit VGA 模式 (已有人實測過)
    // 輸出速率 = APLL / clkm_div_num(2) / tx_bck_div_num(1) / 2, 所以 APLL 要設成 sample 速率的 4 倍
    I2S1.conf2.val = 0;
    I2S1.conf2.lcd_en = 1;
    I2S1.conf2.lcd_tx_wrx2_en = 1;

    I2S1.sample_rate_conf.val = 0;
    I2S1.sample_rate_conf.tx_bits_mod = 16;
    I2S1.sample_rate_conf.tx_bck_div_num = 1;

    periph_rtc_apll_acquire();
    uint32_t apllHz = 0;
    periph_rtc_apll_freq_set(SAMPLE_HZ * 4, &apllHz);
    I2S1.clkm_conf.val = 0;
    I2S1.clkm_conf.clkm_div_num = 2;
    I2S1.clkm_conf.clkm_div_a = 1;
    I2S1.clkm_conf.clka_en = 1;  // 時脈來源 = APLL

    I2S1.fifo_conf.val = 0;
    I2S1.fifo_conf.tx_fifo_mod_force_en = 1;
    I2S1.fifo_conf.tx_fifo_mod = 1;
    I2S1.fifo_conf.tx_data_num = 32;
    I2S1.fifo_conf.dscr_en = 1;

    I2S1.conf1.val = 0;
    I2S1.conf1.tx_pcm_bypass = 1;
    I2S1.conf_chan.val = 0;
    I2S1.conf_chan.tx_chan_mod = 1;
    I2S1.conf.tx_right_first = 1;
    I2S1.timing.val = 0;

    I2S1.lc_conf.val = 0;
    I2S1.lc_conf.outdscr_burst_en = 1;
    I2S1.lc_conf.out_data_burst_en = 1;
    I2S1.out_link.addr = (uint32_t)&desc[0] & 0xFFFFF;  // 暫存器只收位址的低 20 bit
    I2S1.out_link.start = 1;
    I2S1.conf.tx_start = 1;
    return apllHz;
}

static void IRAM_ATTR onVsync(void *) { vsCount = vsCount + 1; }

void setup()
{
    Serial.begin(115200);
    buildFrame();
    for (int b = 0; b < 4; b++) {
        routePin(R_PINS[3 - b], b);
        routePin(G_PINS[3 - b], 4 + b);
        routePin(B_PINS[3 - b], 8 + b);
    }
    routePin(HS_PIN, 12);
    routePin(VS_PIN, 13);
    uint32_t apllHz = startI2S();
    Serial.printf("APLL = %lu Hz, sample = %lu Hz (target %lu)\n",
                  (unsigned long)apllHz, (unsigned long)(apllHz / 4), (unsigned long)SAMPLE_HZ);

    // 從 VS 腳讀回自己送出的訊號: 每秒 60 次就代表時脈和整個 DMA 環都對
    gpio_install_isr_service(0);
    gpio_set_intr_type((gpio_num_t)VS_PIN, GPIO_INTR_NEGEDGE);
    gpio_isr_handler_add((gpio_num_t)VS_PIN, onVsync, nullptr);
    gpio_intr_enable((gpio_num_t)VS_PIN);
}

void loop()
{
    static uint32_t last = 0;
    delay(1000);
    uint32_t now = vsCount;
    Serial.printf("VS: %lu /s (expect 60)\n", (unsigned long)(now - last));
    last = now;
}
