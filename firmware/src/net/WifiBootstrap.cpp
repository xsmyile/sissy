#include <WiFi.h>
#include <WiFiManager.h>
#include <esp_system.h>
#include "WifiBootstrap.h"
#include "SerialProvisioning.h"

#if __has_include("secrets.h")
#include "secrets.h"
#endif

// Direct STA connect path used when the desktop app has provisioned WiFi
// credentials over USB serial — keeps the captive portal as a fallback only.
static bool directConnect(const String& ssid, const String& pwd, uint32_t timeoutMs = 20000) {
    WiFi.mode(WIFI_STA);
    WiFi.persistent(true);
    WiFi.begin(ssid.c_str(), pwd.c_str());
    uint32_t start = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - start < timeoutMs) {
        delay(250);
    }
    return WiFi.status() == WL_CONNECTED;
}

#ifndef DEFAULT_SERVER_HOST
#define DEFAULT_SERVER_HOST "sissy.local"
#endif
#ifndef DEFAULT_SERVER_PORT
#define DEFAULT_SERVER_PORT 8787
#endif
#ifndef DEFAULT_SERVER_PATH
#define DEFAULT_SERVER_PATH "/ws"
#endif
#ifndef DEFAULT_AUTH_TOKEN
#define DEFAULT_AUTH_TOKEN ""
#endif
#ifndef DEFAULT_OTA_PASSWORD
#define DEFAULT_OTA_PASSWORD ""
#endif

static String randomSecret(size_t length = 32) {
    static constexpr const char* alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    static constexpr size_t alphabetLen = 62;
    String out;
    out.reserve(length);
    for (size_t i = 0; i < length; i++) {
        out += alphabet[esp_random() % alphabetLen];
    }
    return out;
}

namespace WifiBootstrap {

static constexpr const char* AP_NAME = "Sissy-Setup";
static constexpr const char* AP_PASS = "sissysetup";
static constexpr uint16_t PORTAL_TIMEOUT_S = 600;
static constexpr uint8_t MIN_SECRET_LEN = 12;

RuntimeConfig connect(IDisplay& display) {
    RuntimeConfig cfg = ConfigStore::load();
    bool cfgChanged = false;

    if (cfg.serverHost.length() == 0) cfg.serverHost = DEFAULT_SERVER_HOST;
    if (cfg.serverPort == 0) cfg.serverPort = DEFAULT_SERVER_PORT;
    if (cfg.serverPath.length() == 0) cfg.serverPath = DEFAULT_SERVER_PATH;
    if (cfg.authToken.length() == 0) cfg.authToken = DEFAULT_AUTH_TOKEN;
    if (cfg.otaPassword.length() == 0) {
        cfg.otaPassword = DEFAULT_OTA_PASSWORD;
        cfgChanged = true;
    }
    if (cfg.otaPassword.length() < MIN_SECRET_LEN) {
        cfg.otaPassword = randomSecret();
        cfgChanged = true;
    }

    // Fast path: when the desktop app has provisioned creds + a usable server
    // config over USB serial, skip the captive portal entirely.
    if (cfg.hasWifiCreds() && cfg.isUsable()) {
        display.showBootMessage("wifi", "connecting...");
        if (directConnect(cfg.wifiSsid, cfg.wifiPass)) {
            if (cfgChanged) ConfigStore::save(cfg);
            return cfg;
        }
        display.showError("wifi failed", "starting portal");
        delay(1200);
    }

    WiFiManager wm;
    wm.setDebugOutput(false);
    // Portal runs in non-blocking mode so SerialProvisioning::tick() can
    // accept a `CFG:` line from the desktop app while the captive portal is
    // waiting for a browser submission. Without this, a wiped device sits
    // in startConfigPortal() forever and the app's USB pair flow always
    // times out with "device did not respond in time".
    wm.setConfigPortalBlocking(false);

    char portBuf[8];
    snprintf(portBuf, sizeof(portBuf), "%u", cfg.serverPort);

    WiFiManagerParameter pHost("host", "Server host (mDNS or IP)", cfg.serverHost.c_str(), 64);
    WiFiManagerParameter pPort("port", "Server port", portBuf, 6);
    WiFiManagerParameter pPath("path", "WS path", cfg.serverPath.c_str(), 32);
    WiFiManagerParameter pTok("token", "Bearer token", cfg.authToken.c_str(), 64);
    WiFiManagerParameter pOta("otapw", "OTA password", cfg.otaPassword.c_str(), 32);

    wm.addParameter(&pHost);
    wm.addParameter(&pPort);
    wm.addParameter(&pPath);
    wm.addParameter(&pTok);
    wm.addParameter(&pOta);

    wm.setAPCallback([&display](WiFiManager* m) { display.showPortalHint(AP_NAME, AP_PASS); });

    // Kick the portal off. In non-blocking mode WiFiManager returns the
    // initial `connect` flag (always false here) regardless of whether the
    // AP came up — so the boolean return CANNOT be used as a failure
    // signal. Confirm liveness via getConfigPortalActive() instead.
    (void)wm.startConfigPortal(AP_NAME, AP_PASS);
    if (!wm.getConfigPortalActive()) {
        display.showError("portal failed", "rebooting");
        delay(2000);
        ESP.restart();
    }

    // Drive the portal + serial provisioning ourselves. SerialProvisioning::
    // tick() calls ESP.restart() on a successful CFG, so the only way out of
    // this loop via that branch is a reboot. The browser path exits when
    // getConfigPortalActive() flips false and WiFi is up.
    const uint32_t portalStart = millis();
    while (true) {
        wm.process();
        SerialProvisioning::tick();

        if (!wm.getConfigPortalActive()) {
            if (WiFi.status() == WL_CONNECTED) break;
            display.showError("wifi failed", "rebooting");
            delay(2000);
            ESP.restart();
        }

        if (millis() - portalStart > static_cast<uint32_t>(PORTAL_TIMEOUT_S) * 1000UL) {
            display.showError("portal timeout", "rebooting");
            delay(2000);
            ESP.restart();
        }

        delay(20);
    }

    cfg.serverHost = pHost.getValue();
    cfg.serverPath = pPath.getValue();
    cfg.authToken = pTok.getValue();
    cfg.otaPassword = pOta.getValue();

    long parsedPort = strtol(pPort.getValue(), nullptr, 10);
    if (parsedPort > 0 && parsedPort < 65536) {
        cfg.serverPort = static_cast<uint16_t>(parsedPort);
    }

    ConfigStore::save(cfg);
    return cfg;
}

void forgetAndReboot() {
    WiFiManager wm;
    wm.resetSettings();
    ConfigStore::clear();
    delay(500);
    ESP.restart();
}

}  // namespace WifiBootstrap
