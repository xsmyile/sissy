#pragma once

#include <Arduino.h>
#include "Config.h"
#include "../display/IDisplay.h"

namespace WifiBootstrap {

// Brings up WiFi. If NVS has no usable RuntimeConfig, launches WiFiManager
// captive portal on AP "Sissy-Setup" (password "sissysetup"). The portal
// also collects server host/port/token and saves them to NVS via ConfigStore.
//
// Returns the resolved RuntimeConfig once WiFi is connected. Any other
// outcome — portal timeout, portal failure, serial-CFG success — reboots
// instead of returning.
RuntimeConfig connect(IDisplay& display);

void forgetAndReboot();

}  // namespace WifiBootstrap
