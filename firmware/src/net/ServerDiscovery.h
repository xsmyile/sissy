#pragma once

#include <Arduino.h>
#include <IPAddress.h>

namespace ServerDiscovery {

// Resolves an mDNS host (e.g. "sissy.local") to an IP. Returns true on
// success. If the host is already an IP literal or a non-.local hostname,
// returns false and the caller should pass the host string straight through
// to the HTTP/WS client.
bool resolveMdns(const String& host, IPAddress& out);

}  // namespace ServerDiscovery
