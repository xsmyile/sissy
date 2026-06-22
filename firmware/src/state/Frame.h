#pragma once

#include <Arduino.h>

enum MascotState : uint8_t {
    MS_CODING = 0,
    MS_SLEEPING,
    MS_TRENDING,
    MS_THINKING,
    MS_GLOWING,
    MS_ANGRY_COFFEE,
    MS_OFFLINE,
    MS_COUNT,
};

struct Frame {
    String cost = "...";
    MascotState state = MS_SLEEPING;
    String primary = "...";
    String primaryLabel = "TOKENS";
};

MascotState stateFromName(const String& s);
