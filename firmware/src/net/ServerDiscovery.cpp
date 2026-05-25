#include <ESPmDNS.h>
#include "ServerDiscovery.h"

namespace ServerDiscovery {

// mDNS is owned by Ota::begin() which runs first in setup(). Calling
// MDNS.begin() again here would return false on the ESP32 core, so we just
// query whatever the OTA-side init already brought up.
bool resolveMdns(const String& host, IPAddress& out) {
    if (!host.endsWith(".local")) return false;

    String bare = host.substring(0, host.length() - 6);
    IPAddress ip = MDNS.queryHost(bare);
    if (ip == IPAddress(0, 0, 0, 0)) return false;

    out = ip;
    return true;
}

}  // namespace ServerDiscovery
