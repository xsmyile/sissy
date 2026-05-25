#include <ArduinoOTA.h>
#include "Ota.h"

namespace Ota {

void begin(const String& hostname, const String& password) {
    ArduinoOTA.setHostname(hostname.c_str());
    if (password.length() > 0) {
        ArduinoOTA.setPassword(password.c_str());
    }
    ArduinoOTA.begin();
}

void loop() {
    ArduinoOTA.handle();
}

}  // namespace Ota
