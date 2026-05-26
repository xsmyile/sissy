#include "SSD1306Display.h"
#include "../sprites_mono.h"

static constexpr int SCREEN_W = 128;
static constexpr int SCREEN_H = 64;

// Order must match the MS_* enum in state/MascotState. The trailing entry
// covers MS_OFFLINE and aliases `sleeping` until a dedicated "no signal"
// sprite ships — keeps the array dense (indexable by enum) without a new
// PNG round-trip.
static const uint8_t* const SPRITES[MS_COUNT] = {
    coding, sleeping, trending, thinking, glowing, angry_coffee, sleeping,
};

SSD1306Display::SSD1306Display(uint8_t i2cAddr) : _display(SCREEN_W, SCREEN_H, &Wire, -1), _addr(i2cAddr) {}

bool SSD1306Display::begin() {
#if defined(OLED_SDA) && defined(OLED_SCL)
    Wire.begin(OLED_SDA, OLED_SCL);
#else
    Wire.begin();
#endif
    if (!_display.begin(SSD1306_SWITCHCAPVCC, _addr)) {
        return false;
    }
    setBrightness(0x40);
    clear();
    return true;
}

void SSD1306Display::clear() {
    _display.clearDisplay();
    _display.display();
}

void SSD1306Display::setBrightness(uint8_t value) {
    _display.ssd1306_command(SSD1306_SETCONTRAST);
    _display.ssd1306_command(value);
}

void SSD1306Display::drawTextScreen(const char* title, const char* line1, const char* line2) {
    _display.clearDisplay();
    _display.setTextColor(SSD1306_WHITE);

    _display.setTextSize(1);
    _display.setCursor(0, 0);
    _display.println(title);
    _display.drawLine(0, 9, SCREEN_W - 1, 9, SSD1306_WHITE);

    _display.setCursor(0, 16);
    _display.println(line1);
    if (line2) {
        _display.setCursor(0, 28);
        _display.println(line2);
    }
    _display.display();
}

void SSD1306Display::showBootMessage(const char* line1, const char* line2) {
    drawTextScreen("sissy", line1, line2);
}

void SSD1306Display::showPortalHint(const char* apName, const char* apPassword) {
    _display.clearDisplay();
    _display.setTextColor(SSD1306_WHITE);

    _display.setTextSize(1);
    _display.setCursor(0, 0);
    _display.println(F("WiFi setup"));
    _display.drawLine(0, 9, SCREEN_W - 1, 9, SSD1306_WHITE);

    _display.setCursor(0, 14);
    _display.print(F("Join AP:"));
    _display.setCursor(0, 24);
    _display.println(apName);

    _display.setCursor(0, 36);
    _display.print(F("Pass:"));
    _display.setCursor(0, 46);
    _display.println(apPassword);

    _display.setCursor(0, 56);
    _display.print(F("then 192.168.4.1"));

    _display.display();
}

void SSD1306Display::showError(const char* line1, const char* line2) {
    drawTextScreen("error", line1, line2);
}

void SSD1306Display::render(const Frame& frame, uint32_t nowMs) {
    _display.clearDisplay();
    _display.setTextColor(SSD1306_WHITE);

    const int mx = 0;
    const int my = (SCREEN_H - SPRITE_H) / 2;

    if (frame.state == MS_OFFLINE) {
        _display.drawBitmap(mx, my, SPRITES[MS_OFFLINE], SPRITE_W, SPRITE_H, SSD1306_WHITE);
        drawOfflineGlyph(SCREEN_W - 14, 2);
        const int rx = SPRITE_W + 6;
        _display.setTextSize(1);
        _display.setCursor(rx, 28);
        _display.print(F("offline"));
        _display.display();
        return;
    }

    // Subtle ±1 px vertical bob keeps mascot looking alive without lying
    // about the wire state. The menubar mirror does not animate, so this
    // must not change which sprite is drawn — only its draw offset.
    static const int BOB_STEPS[4] = {0, 1, 0, -1};
    const int bob = BOB_STEPS[(nowMs / 1000UL) & 3];
    _display.drawBitmap(mx, my + bob, SPRITES[frame.state], SPRITE_W, SPRITE_H, SSD1306_WHITE);

    const int rx = SPRITE_W + 6;

    _display.setTextSize(1);
    _display.setCursor(rx, 0);
    _display.print(frame.primaryLabel);
    _display.drawLine(rx, 9, rx + 36, 9, SSD1306_WHITE);

    _display.setTextSize(2);
    _display.setCursor(rx, 12);
    _display.print(frame.primary);

    _display.setTextSize(1);
    _display.setCursor(rx, 34);
    _display.print(F("COST $"));
    _display.drawLine(rx, 43, rx + 36, 43, SSD1306_WHITE);

    _display.setTextSize(2);
    _display.setCursor(rx, 46);
    _display.print(frame.cost);

    _display.display();
}

void SSD1306Display::drawOfflineGlyph(int x, int y) {
    // 12x12 "no signal": three concentric arcs + diagonal slash.
    _display.drawCircle(x + 6, y + 9, 2, SSD1306_WHITE);
    _display.drawCircle(x + 6, y + 9, 5, SSD1306_WHITE);
    _display.drawCircle(x + 6, y + 9, 8, SSD1306_WHITE);
    _display.drawLine(x, y + 11, x + 11, y, SSD1306_WHITE);
}
