#include <Preferences.h>
#include "Config.h"

static Preferences prefs;
static constexpr const char* NS = "sissy";

namespace ConfigStore {

RuntimeConfig load() {
    RuntimeConfig cfg;
    prefs.begin(NS, true);
    cfg.wifiSsid = prefs.getString("ssid", "");
    cfg.wifiPass = prefs.getString("pwd", "");
    cfg.serverHost = prefs.getString("host", "");
    cfg.serverPort = prefs.getUShort("port", 0);
    cfg.serverPath = prefs.getString("path", "/ws");
    cfg.authToken = prefs.getString("token", "");
    cfg.otaPassword = prefs.getString("otapw", "");
    prefs.end();
    return cfg;
}

void save(const RuntimeConfig& cfg) {
    prefs.begin(NS, false);
    prefs.putString("ssid", cfg.wifiSsid);
    prefs.putString("pwd", cfg.wifiPass);
    prefs.putString("host", cfg.serverHost);
    prefs.putUShort("port", cfg.serverPort);
    prefs.putString("path", cfg.serverPath);
    prefs.putString("token", cfg.authToken);
    prefs.putString("otapw", cfg.otaPassword);
    prefs.end();
}

void clear() {
    prefs.begin(NS, false);
    prefs.clear();
    prefs.end();
}

}  // namespace ConfigStore
