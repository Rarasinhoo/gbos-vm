// Stand-in for AOSP's libbase properties API, for building Mesa's gfxstream guest outside AOSP.
// Only GetProperty is used (to tell minigbm from goldfish gralloc); bionic provides the rest.
#pragma once
#include <string>
#include <sys/system_properties.h>
namespace android {
namespace base {
inline std::string GetProperty(const std::string& key, const std::string& default_value) {
    char value[PROP_VALUE_MAX] = {};
    return __system_property_get(key.c_str(), value) > 0 ? std::string(value) : default_value;
}
}  // namespace base
}  // namespace android
