#pragma once

#include <Arduino.h>

struct RuntimeConfig {
    String wifiSsid;
    String wifiPass;
    String serverHost;
    uint16_t serverPort = 0;
    String serverPath;
    String authToken;
    String otaPassword;

    bool isUsable() const {
        return serverHost.length() > 0 && serverPort > 0 && authToken.length() > 0;
    }

    // Used by main.cpp to decide whether to skip the captive portal entirely
    // and go straight to a direct WiFi.begin(). When the desktop app does
    // serial provisioning, the WiFi creds arrive over USB too.
    bool hasWifiCreds() const {
        return wifiSsid.length() > 0 && wifiPass.length() > 0;
    }
};

namespace ConfigStore {
    RuntimeConfig load();
    void save(const RuntimeConfig& cfg);
    void clear();
}
