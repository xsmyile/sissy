// Sissy firmware — ESP32 WROOM-32, WiFi + WebSocket client, no serial fallback.
//
// Boot flow:
//   1. OLED init, show "booting"
//   2. WifiBootstrap.connect() — WiFiManager portal if NVS empty, otherwise reconnect
//   3. ArduinoOTA up (wireless flashes)
//   4. WsClient.begin() — connects, sends hello, listens for frame push
//   5. loop() renders latest frame + breath animation, handles OTA + WS reconnect

#include <Arduino.h>
#include <WiFi.h>

#include "display/SSD1306Display.h"
#include "net/Config.h"
#include "net/WifiBootstrap.h"
#include "net/WsClient.h"
#include "net/Ota.h"
#include "net/SerialProvisioning.h"
#include "state/Frame.h"

#ifndef SISSY_FW_VERSION
#define SISSY_FW_VERSION "dev"
#endif

static SSD1306Display gDisplay;
static WsClient gWs;
static Frame gFrame;
static RuntimeConfig gCfg;
static String gDeviceId;
static uint32_t gLastFrameAt = 0;
// First-disconnect timestamp, cleared on every successful WS connect. Lets
// the offline mascot trigger on a confirmed link drop rather than waiting
// for a stale-frame timeout — the previous `gLastFrameAt`-based check meant
// the OLED kept rendering the last-known frame for 15 s after the daemon
// stopped, which looked indistinguishable from "still running".
static uint32_t gDisconnectedAt = 0;

static String deviceIdFromMac() {
    uint8_t mac[6];
    WiFi.macAddress(mac);
    char buf[14];
    snprintf(buf, sizeof(buf), "esp-%02x%02x%02x", mac[3], mac[4], mac[5]);
    return String(buf);
}

// Hold the on-board BOOT button (GPIO 0) at power-up to wipe stored WiFi +
// server credentials. Useful when moving the device to a new network or
// retargeting the server URL without a reflash.
static constexpr int RESET_BUTTON_PIN = 0;
static constexpr uint32_t RESET_HOLD_MS = 2000;

static bool resetButtonHeld() {
    pinMode(RESET_BUTTON_PIN, INPUT_PULLUP);
    if (digitalRead(RESET_BUTTON_PIN) != LOW) return false;
    uint32_t start = millis();
    while (digitalRead(RESET_BUTTON_PIN) == LOW) {
        if (millis() - start > RESET_HOLD_MS) return true;
        delay(20);
    }
    return false;
}

void setup() {
    Serial.begin(115200);
    delay(50);

    if (!gDisplay.begin()) {
        // No display means no UX — stall instead of silently running headless.
        while (true) {
            delay(1000);
        }
    }
    gDisplay.showBootMessage("booting", SISSY_FW_VERSION);
    SerialProvisioning::announce(SISSY_FW_VERSION);

    if (resetButtonHeld()) {
        gDisplay.showBootMessage("reset hold", "wiping nvs");
        delay(1000);
        WifiBootstrap::forgetAndReboot();
        // never returns
    }
    gCfg = WifiBootstrap::connect(gDisplay);
    gDeviceId = deviceIdFromMac();

    gDisplay.showBootMessage("wifi up", WiFi.localIP().toString().c_str());
    delay(800);

    Ota::begin(gDeviceId, gCfg.otaPassword);

    gWs.onStatus([](bool up) {
        if (up) {
            gDisconnectedAt = 0;
        } else {
            gDisplay.showBootMessage("ws down", "retrying...");
            // Latch the first-disconnect time. WStype_DISCONNECTED fires
            // again on every failed reconnect attempt; overwriting here
            // would keep the threshold from ever elapsing during a long
            // outage.
            if (gDisconnectedAt == 0) {
                uint32_t now = millis();
                gDisconnectedAt = (now == 0) ? 1 : now;
            }
        }
    });
    gWs.onFrame([](const Frame& f) {
        gFrame = f;
        gLastFrameAt = millis();
    });
    gWs.begin(gCfg, gDeviceId);
}

void loop() {
    SerialProvisioning::tick();
    Ota::loop();
    gWs.loop();

    // 15 s matches AGENTS.md and the daemon's WS heartbeat cadence. A
    // single missed ping (~10 s) shouldn't flip the mascot; two missed
    // pings should.
    static constexpr uint32_t OFFLINE_THRESHOLD_MS = 15000;

    static uint32_t lastRender = 0;
    const uint32_t now = millis();
    if (now - lastRender > 80) {
        lastRender = now;
        if (gWs.isConnected() || gLastFrameAt > 0) {
            const bool offline =
                !gWs.isConnected() && gDisconnectedAt > 0 && (now - gDisconnectedAt) > OFFLINE_THRESHOLD_MS;
            if (offline) {
                Frame f = gFrame;
                f.state = MS_OFFLINE;
                gDisplay.render(f, now);
            } else {
                gDisplay.render(gFrame, now);
            }
        }
    }

    // Dim OLED after 5 min of no fresh frame to save the panel.
    static bool dimmed = false;
    if (!dimmed && gLastFrameAt > 0 && now - gLastFrameAt > 5UL * 60UL * 1000UL) {
        gDisplay.setBrightness(0x10);
        dimmed = true;
    } else if (dimmed && now - gLastFrameAt < 5UL * 60UL * 1000UL) {
        gDisplay.setBrightness(0x40);
        dimmed = false;
    }
}
