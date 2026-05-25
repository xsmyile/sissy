#pragma once

#include <Arduino.h>
#include "../state/Frame.h"

// Display abstraction. SSD1306Display is the V1 implementation; a future
// ST7735Display (color TFT) plugs in here without touching the rest of the
// firmware.
class IDisplay {
public:
    virtual ~IDisplay() = default;

    virtual bool begin() = 0;
    virtual void clear() = 0;

    virtual void showBootMessage(const char* line1, const char* line2) = 0;
    virtual void showPortalHint(const char* apName, const char* apPassword) = 0;
    virtual void showError(const char* line1, const char* line2) = 0;

    virtual void render(const Frame& frame, uint32_t nowMs) = 0;
    virtual void setBrightness(uint8_t value) = 0;
};
