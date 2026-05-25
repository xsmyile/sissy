#pragma once

#include <Arduino.h>

namespace Ota {

void begin(const String& hostname, const String& password);
void loop();

}  // namespace Ota
