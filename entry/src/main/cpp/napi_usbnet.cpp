// USB network, the NAPI side: usbnetStart / usbnetStop / usbnetStatus for
// UsbNetAbility (a VpnExtensionAbility), which opens the VPN and hands its tun
// fd here. The tunnel itself is usbnet_tunnel.h; see there for how it works.

#include "usbnet_tunnel.h"

#include <napi/native_api.h>

#include <exception>
#include <memory>
#include <mutex>
#include <string>

namespace {

using usbnet::Tunnel;

/**
 * The one tunnel this module runs. Deliberately never destroyed: a Tunnel
 * joining threads from a static destructor at process exit is not something to
 * rely on, so the holder outlives everything (the usual leaky-singleton idiom).
 */
struct Module {
    std::mutex mutex;
    std::unique_ptr<Tunnel> tunnel;
};

Module &TheModule()
{
    // Never freed, on purpose (see above); the state in it is what the module is for.
    static auto *module = new Module();  // NOLINT(cppcoreguidelines-owning-memory,cppcoreguidelines-avoid-non-const-global-variables)
    return *module;
}

/** Reports an exception to JS instead of letting it unwind into the engine. */
void ThrowToJs(napi_env env, const char *what)
{
    napi_throw_error(env, nullptr, what);
}

bool GetInt(napi_env env, napi_value value, int32_t *out)
{
    return napi_get_value_int32(env, value, out) == napi_ok;
}

napi_value Start(napi_env env, napi_callback_info info)
{
    try {
        size_t argc = 2;
        napi_value args[2] = {nullptr, nullptr};
        int32_t tun = -1;
        int32_t port = 0;
        if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 2 ||
            !GetInt(env, args[0], &tun) || !GetInt(env, args[1], &port) || tun < 0 || port <= 0 || port > 65535) {
            ThrowToJs(env, "usbnetStart(tunFd, port)");
            return nullptr;
        }
        Module &m = TheModule();
        std::lock_guard<std::mutex> lock(m.mutex);
        m.tunnel.reset();  // stops and joins the previous one first
        m.tunnel = std::make_unique<Tunnel>(tun, port);
    } catch (const std::exception &e) {
        ThrowToJs(env, e.what());
    } catch (...) {
        ThrowToJs(env, "usbnetStart failed");
    }
    return nullptr;
}

napi_value Stop(napi_env env, napi_callback_info /* info */)
{
    try {
        Module &m = TheModule();
        std::unique_ptr<Tunnel> old;
        {
            std::lock_guard<std::mutex> lock(m.mutex);
            old = std::move(m.tunnel);
        }
        old.reset();  // joins outside the lock; returns at once, the threads wake on the stop signal
    } catch (const std::exception &e) {
        ThrowToJs(env, e.what());
    } catch (...) {
        ThrowToJs(env, "usbnetStop failed");
    }
    return nullptr;
}

napi_value Status(napi_env env, napi_callback_info /* info */)
{
    try {
        std::string s = "off";
        {
            Module &m = TheModule();
            std::lock_guard<std::mutex> lock(m.mutex);
            if (m.tunnel != nullptr) {
                s = m.tunnel->Status();
            }
        }
        napi_value out = nullptr;
        if (napi_create_string_utf8(env, s.c_str(), s.size(), &out) != napi_ok) {
            ThrowToJs(env, "usbnetStatus: cannot make a string");
            return nullptr;
        }
        return out;
    } catch (const std::exception &e) {
        ThrowToJs(env, e.what());
    } catch (...) {
        ThrowToJs(env, "usbnetStatus failed");
    }
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"usbnetStart", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"usbnetStop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"usbnetStatus", nullptr, Status, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc) != napi_ok) {
        OH_LOG_ERROR(LOG_APP, "cannot define the usbnet functions");
    }
    return exports;
}

}  // namespace

EXTERN_C_START
// napi_module_register takes a non-const pointer and keeps it.
static napi_module g_module = {  // NOLINT(cppcoreguidelines-avoid-non-const-global-variables)
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "usbnet",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

__attribute__((constructor)) void RegisterUsbNet(void)
{
    napi_module_register(&g_module);
}
EXTERN_C_END
