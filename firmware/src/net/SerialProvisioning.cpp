#include <ArduinoJson.h>
#include "SerialProvisioning.h"
#include "Config.h"

namespace SerialProvisioning {

static constexpr const char* CFG_PREFIX = "CFG:";
static constexpr size_t MAX_LINE = 1024;

static String buf;

void announce(const char* fwVersion) {
    Serial.print(F("SISSY:"));
    Serial.print(fwVersion);
    Serial.println(F(":ready"));
}

static void respondError(const char* msg) {
    Serial.print(F("ERR:"));
    Serial.println(msg);
}

static void respondOk() {
    Serial.println(F("OK:saved,rebooting"));
    Serial.flush();
}

static void apply(const String& json) {
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, json);
    if (err) {
        respondError(err.c_str());
        return;
    }

    if (!doc["v"].is<int>() || doc["v"].as<int>() != 1) {
        respondError("unsupported v");
        return;
    }
    const char* type = doc["type"] | "";
    if (strcmp(type, "config") != 0) {
        respondError("not a config message");
        return;
    }

    RuntimeConfig cfg = ConfigStore::load();
    cfg.wifiSsid = String((const char*)(doc["ssid"] | cfg.wifiSsid.c_str()));
    cfg.wifiPass = String((const char*)(doc["pwd"] | cfg.wifiPass.c_str()));
    cfg.serverHost = String((const char*)(doc["server"]["host"] | cfg.serverHost.c_str()));
    long port = doc["server"]["port"] | (long)cfg.serverPort;
    if (port > 0 && port < 65536) cfg.serverPort = static_cast<uint16_t>(port);
    cfg.serverPath = String((const char*)(doc["server"]["path"] | cfg.serverPath.c_str()));
    cfg.authToken = String((const char*)(doc["server"]["token"] | cfg.authToken.c_str()));
    cfg.otaPassword = String((const char*)(doc["ota"]["password"] | cfg.otaPassword.c_str()));

    ConfigStore::save(cfg);
    respondOk();
    delay(200);
    ESP.restart();
}

void tick() {
    while (Serial.available()) {
        char c = (char)Serial.read();
        if (c == '\r') continue;
        if (c == '\n') {
            if (buf.startsWith(CFG_PREFIX)) {
                String payload = buf.substring(strlen(CFG_PREFIX));
                buf = "";
                apply(payload);
                return;
            }
            buf = "";
        } else {
            buf += c;
            if (buf.length() > MAX_LINE) {
                buf = "";
                respondError("line too long");
            }
        }
    }
}

}  // namespace SerialProvisioning
