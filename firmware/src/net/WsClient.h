#pragma once

#include <Arduino.h>
#include <functional>
#include "Config.h"
#include "../state/Frame.h"

class WsClient {
 public:
    using FrameCallback = std::function<void(const Frame&)>;
    using StatusCallback = std::function<void(bool connected)>;

    void begin(const RuntimeConfig& cfg, const String& deviceId);
    void loop();

    void onFrame(FrameCallback cb) { _frameCb = std::move(cb); }
    void onStatus(StatusCallback cb) { _statusCb = std::move(cb); }

    bool isConnected() const { return _connected; }

    // Called from the C-style WebSocketsClient event trampoline; not part of
    // the public client API but exposed so the static callback can dispatch
    // back into the active instance.
    void onConnectedInternal();
    void onDisconnectedInternal();
    void sendHelloInternal();
    void handleTextInternal(const char* data, size_t len);

 private:
    void sendHello();
    void handleText(const char* data, size_t len);
    uint32_t nextBackoffMs();

    RuntimeConfig _cfg;
    String _deviceId;
    // _authHeader must outlive every call to gWs.loop(): WebSocketsClient
    // keeps the const char* we pass to setExtraHeaders and re-sends it on
    // every reconnect handshake. Storing it as an instance member keeps it
    // alive for the lifetime of the client.
    String _authHeader;
    bool _connected = false;
    uint8_t _reconnectFailures = 0;
    FrameCallback _frameCb;
    StatusCallback _statusCb;
};
