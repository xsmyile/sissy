#include <WebSocketsClient.h>
#include <ArduinoJson.h>
#include "WsClient.h"
#include "ServerDiscovery.h"

static WebSocketsClient gWs;
static WsClient* gOwner = nullptr;

static void onEvent(WStype_t type, uint8_t* payload, size_t length) {
    if (!gOwner) return;
    switch (type) {
        case WStype_CONNECTED:
            gOwner->onConnectedInternal();
            gOwner->sendHelloInternal();
            break;
        case WStype_DISCONNECTED:
            gOwner->onDisconnectedInternal();
            break;
        case WStype_TEXT: {
            String s;
            s.reserve(length);
            for (size_t i = 0; i < length; i++) s += static_cast<char>(payload[i]);
            gOwner->handleTextInternal(s);
            break;
        }
        default:
            break;
    }
}

void WsClient::begin(const RuntimeConfig& cfg, const String& deviceId) {
    _cfg = cfg;
    _deviceId = deviceId;
    gOwner = this;

    IPAddress ip;
    bool useIp = ServerDiscovery::resolveMdns(_cfg.serverHost, ip);

    String url = _cfg.serverPath;
    _authHeader = "Authorization: Bearer " + _cfg.authToken;
    gWs.setExtraHeaders(_authHeader.c_str());
    _reconnectFailures = 0;
    gWs.setReconnectInterval(nextBackoffMs());
    gWs.enableHeartbeat(15000, 5000, 2);

    if (useIp) {
        gWs.begin(ip.toString().c_str(), _cfg.serverPort, url.c_str());
    } else {
        gWs.begin(_cfg.serverHost.c_str(), _cfg.serverPort, url.c_str());
    }
    gWs.onEvent(onEvent);
}

void WsClient::loop() {
    gWs.loop();
}

void WsClient::sendHello() {
    JsonDocument doc;
    doc["type"] = "hello";
    doc["fw"] = SISSY_FW_VERSION;
    doc["device"] = _deviceId;
    String out;
    serializeJson(doc, out);
    gWs.sendTXT(out);
}

void WsClient::handleText(const String& payload) {
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, payload);
    if (err) return;

    const char* type = doc["type"] | "";
    if (strcmp(type, "frame") != 0) return;

    Frame f;
    f.tokens = String((const char*)(doc["tokens"] | "..."));
    f.cost = String((const char*)(doc["cost"] | "..."));
    f.burn = String((const char*)(doc["burn"] | "..."));
    f.state = stateFromName(String((const char*)(doc["state"] | "think")));
    f.ts = doc["ts"] | 0;
    // Back-compat: pre-burn-rate servers send only `tokens`. Fall back so
    // older deployments keep rendering instead of going blank.
    f.primary = String((const char*)(doc["primary"] | doc["tokens"] | "..."));
    f.primaryLabel = String((const char*)(doc["primary_label"] | "TOKENS"));

    if (_frameCb) _frameCb(f);
}

// Exponential backoff with jitter: 1s base, doubling per failure, capped at 10s.
// Reset on successful CONNECTED so a flapping link doesn't pile up delay forever.
// Short ceiling keeps the OLED's "back from offline" window predictable —
// worst-case 10s after the daemon is reachable again, even from deep backoff.
static constexpr uint32_t WS_BACKOFF_BASE_MS = 1000;
static constexpr uint32_t WS_BACKOFF_MAX_MS = 10000;
static constexpr uint8_t WS_BACKOFF_MAX_STEPS = 4;  // 1s * 2^4 = 16s, clamp to 10s

uint32_t WsClient::nextBackoffMs() {
    uint32_t shifted = WS_BACKOFF_BASE_MS << _reconnectFailures;
    if (shifted > WS_BACKOFF_MAX_MS || shifted < WS_BACKOFF_BASE_MS) {
        shifted = WS_BACKOFF_MAX_MS;
    }
    uint32_t jitter = (uint32_t)random(0, (long)(shifted / 4));
    return shifted - (shifted / 8) + jitter;
}

// Bridge functions called by the C-style static callback.
void WsClient::onConnectedInternal() {
    _connected = true;
    _reconnectFailures = 0;
    gWs.setReconnectInterval(WS_BACKOFF_BASE_MS);
    if (_statusCb) _statusCb(true);
}

void WsClient::onDisconnectedInternal() {
    _connected = false;
    if (_reconnectFailures < WS_BACKOFF_MAX_STEPS) _reconnectFailures++;
    gWs.setReconnectInterval(nextBackoffMs());
    if (_statusCb) _statusCb(false);
}

void WsClient::sendHelloInternal() {
    sendHello();
}
void WsClient::handleTextInternal(const String& s) {
    handleText(s);
}
