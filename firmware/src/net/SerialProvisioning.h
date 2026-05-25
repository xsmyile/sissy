#pragma once

#include <Arduino.h>

namespace SerialProvisioning {

// Prints a one-line "SISSY:<fw>:ready" banner so the desktop app's serial
// probe can identify this device among the user's /dev/cu.* nodes.
void announce(const char* fwVersion);

// Non-blocking pump. Call from loop(). Reads available serial bytes, looks
// for a `CFG:{...json...}\n` line, parses it, persists to NVS, and reboots.
// Any unrelated traffic is ignored, so debug prints still work fine.
void tick();

}  // namespace SerialProvisioning
