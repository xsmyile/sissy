#include "Frame.h"

struct StateMapping {
    const char* name;
    MascotState id;
};

static const StateMapping STATE_MAP[] = {
    {"code", MS_CODING},    {"sleep", MS_SLEEPING}, {"trend", MS_TRENDING},
    {"think", MS_THINKING}, {"glow", MS_GLOWING},   {"angry", MS_ANGRY_COFFEE},
};
static const uint8_t STATE_MAP_LEN = sizeof(STATE_MAP) / sizeof(STATE_MAP[0]);

MascotState stateFromName(const String& s) {
    for (uint8_t i = 0; i < STATE_MAP_LEN; i++) {
        if (s.equalsIgnoreCase(STATE_MAP[i].name)) return STATE_MAP[i].id;
    }
    return MS_THINKING;
}

const char* stateToName(MascotState s) {
    for (uint8_t i = 0; i < STATE_MAP_LEN; i++) {
        if (STATE_MAP[i].id == s) return STATE_MAP[i].name;
    }
    return "think";
}
