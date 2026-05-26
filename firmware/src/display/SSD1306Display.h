#pragma once

#include <Adafruit_SSD1306.h>
#include "IDisplay.h"

class SSD1306Display : public IDisplay {
 public:
    SSD1306Display(uint8_t i2cAddr = 0x3C);

    bool begin() override;
    void clear() override;

    void showBootMessage(const char* line1, const char* line2) override;
    void showPortalHint(const char* apName, const char* apPassword) override;
    void showError(const char* line1, const char* line2) override;

    void render(const Frame& frame, uint32_t nowMs) override;
    void setBrightness(uint8_t value) override;

 private:
    Adafruit_SSD1306 _display;
    uint8_t _addr;

    void drawTextScreen(const char* title, const char* line1, const char* line2);
    void drawOfflineGlyph(int x, int y);
};
