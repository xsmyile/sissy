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
    String tokens = "...";
    String cost = "...";
    String burn = "...";
    MascotState state = MS_SLEEPING;
    uint32_t ts = 0;
    String primary = "...";
    String primaryLabel = "TOKENS";
};

MascotState stateFromName(const String& s);
const char* stateToName(MascotState s);
