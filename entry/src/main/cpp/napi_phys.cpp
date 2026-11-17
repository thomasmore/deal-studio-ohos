// Physics, the NAPI side: the functions of phys_world.h under the names ArkTS imports from
// libphys.so (types/libphys/index.d.ts). Glue only; the world is PhysWorld.
//
// When PHYS_STUB is defined (Jolt not fetched, see CMakeLists.txt) every function is a no-op and
// physInit() returns 0, which ArkTS reads as "physics not available".

#include <napi/native_api.h>

#ifndef PHYS_STUB
#include "phys_stepper.h"
#include "phys_world.h"

#include <chrono>
#include <cmath>
#include <thread>
#endif

namespace {

double Arg(napi_env env, napi_value *argv, size_t argc, size_t i)
{
    double v = 0;
    if (i < argc) {
        napi_get_value_double(env, argv[i], &v);
    }
    return v;
}

napi_value Num(napi_env env, double v)
{
    napi_value r;
    napi_create_double(env, v, &r);
    return r;
}

#define ARGS(n)                                                                  \
    size_t argc = n;                                                             \
    napi_value argv[n];                                                          \
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr)

#define F(a, i) static_cast<float>(Arg(env, argv, argc, i))
#define I(a, i) static_cast<int>(Arg(env, argv, argc, i))

#ifdef PHYS_STUB

napi_value Stub(napi_env env, napi_callback_info) { return Num(env, 0); }
#define HANDLER(name) Stub

#else

vphys::PhysWorld &World()
{
    // Never destroyed on purpose: no Jolt teardown from a static destructor at process exit.
    static vphys::PhysWorld *w = new vphys::PhysWorld();
    return *w;
}

// The thread a step runs on (physStepBegin / physStepEnd). Never destroyed either: its thread would be joined from a
// static destructor at exit.
vphys::StepRunner &Stepper()
{
    static vphys::StepRunner *s = new vphys::StepRunner();
    return *s;
}

// The world as it is once any step in flight has finished: every function but the step's own goes through this, so
// the world is never touched while the step thread runs.
vphys::PhysWorld &Idle()
{
    Stepper().wait();
    return World();
}

// The float array behind a Float32Array argument, or null; *length is how many floats may be
// written to it (vphys::FloatCapacity: not napi_get_typedarray_info's length, which is in bytes on
// OpenHarmony).
float *FloatArray(napi_env env, napi_value v, size_t *length)
{
    napi_typedarray_type type;
    void *data = nullptr;
    napi_value buffer = nullptr;
    size_t offset = 0;
    size_t reported = 0;
    *length = 0;
    if (napi_get_typedarray_info(env, v, &type, &reported, &data, &buffer, &offset) != napi_ok ||
        type != napi_float32_array || data == nullptr || buffer == nullptr) {
        return nullptr;
    }
    void *bufferData = nullptr;
    size_t bufferBytes = 0;
    if (napi_get_arraybuffer_info(env, buffer, &bufferData, &bufferBytes) != napi_ok) {
        return nullptr;
    }
    napi_value lengthValue;
    double jsLength = -1;
    if (napi_get_named_property(env, v, "length", &lengthValue) != napi_ok ||
        napi_get_value_double(env, lengthValue, &jsLength) != napi_ok) {
        return nullptr;
    }
    *length = vphys::FloatCapacity(jsLength, reported, bufferBytes, offset);
    return *length > 0 ? static_cast<float *>(data) : nullptr;
}

napi_value PhysInit(napi_env env, napi_callback_info info)
{
    ARGS(2);
    int maxBodies = argc > 0 ? I(0, 0) : 2048;
    unsigned hw = std::thread::hardware_concurrency();
    int threads = argc > 1 ? I(0, 1) : (hw > 2 ? static_cast<int>(std::min(3u, hw - 1)) : 0);
    Idle().init(maxBodies <= 0 ? 2048 : maxBodies, threads);
    return Num(env, Idle().ready() ? (threads > 0 ? threads : 1) : 0);
}
napi_value PhysReset(napi_env env, napi_callback_info) { Idle().reset(); return nullptr; }
napi_value PhysSetGravity(napi_env env, napi_callback_info info)
{
    ARGS(1);
    Idle().setGravity(F(0, 0));
    return nullptr;
}
napi_value PhysSetBound(napi_env env, napi_callback_info info)
{
    ARGS(3);
    Idle().setBound(F(0, 0), F(0, 1), F(0, 2));
    return nullptr;
}
napi_value PhysAddBox(napi_env env, napi_callback_info info)
{
    ARGS(4);
    return Num(env, Idle().addBox(F(0, 0), F(0, 1), F(0, 2), I(0, 3)));
}
napi_value PhysAddSphere(napi_env env, napi_callback_info info)
{
    ARGS(2);
    return Num(env, Idle().addSphere(F(0, 0), I(0, 1)));
}
napi_value PhysAddCylinder(napi_env env, napi_callback_info info)
{
    ARGS(3);
    return Num(env, Idle().addCylinder(F(0, 0), F(0, 1), I(0, 2)));
}
// physAddParts(records, points, kind): a body of convex parts, see PhysWorld::addParts.
napi_value PhysAddParts(napi_env env, napi_callback_info info)
{
    ARGS(3);
    size_t recordFloats = 0;
    size_t pointFloats = 0;
    const float *records = argc > 0 ? FloatArray(env, argv[0], &recordFloats) : nullptr;
    const float *points = argc > 1 ? FloatArray(env, argv[1], &pointFloats) : nullptr;
    int count = static_cast<int>(recordFloats / vphys::PhysWorld::kPartRecord);
    return Num(env, records ? Idle().addParts(records, count, points, points ? pointFloats : 0, I(0, 2)) : -1);
}
napi_value PhysRemove(napi_env env, napi_callback_info info)
{
    ARGS(1);
    Idle().remove(I(0, 0));
    return nullptr;
}
napi_value PhysSetPose(napi_env env, napi_callback_info info)
{
    ARGS(8);
    Idle().setPose(I(0, 0), F(0, 1), F(0, 2), F(0, 3), F(0, 4), F(0, 5), F(0, 6), F(0, 7));
    return nullptr;
}
napi_value PhysSetMaterial(napi_env env, napi_callback_info info)
{
    ARGS(4);
    Idle().setMaterial(I(0, 0), F(0, 1), F(0, 2), F(0, 3));
    return nullptr;
}
napi_value PhysSetVelocity(napi_env env, napi_callback_info info)
{
    ARGS(7);
    Idle().setVelocity(I(0, 0), F(0, 1), F(0, 2), F(0, 3), F(0, 4), F(0, 5), F(0, 6));
    return nullptr;
}
napi_value PhysSleep(napi_env env, napi_callback_info info)
{
    ARGS(1);
    Idle().sleep(I(0, 0));
    return nullptr;
}
napi_value PhysMoveKinematic(napi_env env, napi_callback_info info)
{
    ARGS(9);
    Idle().moveKinematic(I(0, 0), F(0, 1), F(0, 2), F(0, 3), F(0, 4), F(0, 5), F(0, 6), F(0, 7), F(0, 8));
    return nullptr;
}
napi_value PhysStep(napi_env env, napi_callback_info info)
{
    ARGS(2);
    auto t0 = std::chrono::steady_clock::now();
    Idle().step(F(0, 0), argc > 1 ? I(0, 1) : 1);
    auto t1 = std::chrono::steady_clock::now();
    return Num(env, std::chrono::duration<double, std::milli>(t1 - t0).count());
}
// The step on its own thread: begin returns at once, end waits for it and returns the milliseconds it took.
napi_value PhysStepBegin(napi_env env, napi_callback_info info)
{
    ARGS(2);
    float dt = F(0, 0);
    int substeps = argc > 1 ? I(0, 1) : 1;
    Stepper().begin([dt, substeps] { World().step(dt, substeps); });
    return nullptr;
}
napi_value PhysStepEnd(napi_env env, napi_callback_info) { return Num(env, Stepper().end()); }
napi_value PhysReadAwake(napi_env env, napi_callback_info info)
{
    ARGS(1);
    size_t len;
    float *out = argc > 0 ? FloatArray(env, argv[0], &len) : nullptr;
    return Num(env, out ? Idle().readAwake(out, static_cast<int>(len / 8)) : -1);
}
napi_value PhysReadPose(napi_env env, napi_callback_info info)
{
    ARGS(2);
    size_t len;
    float *out = argc > 1 ? FloatArray(env, argv[1], &len) : nullptr;
    return Num(env, out && len >= 7 && Idle().readPose(I(0, 0), out) ? 1 : 0);
}
napi_value PhysDrainContacts(napi_env env, napi_callback_info info)
{
    ARGS(1);
    size_t len;
    float *out = argc > 0 ? FloatArray(env, argv[0], &len) : nullptr;
    return Num(env, out ? Idle().drainContacts(out, static_cast<int>(len / 3)) : -1);
}
napi_value PhysAwakeDynamic(napi_env env, napi_callback_info) { return Num(env, Idle().awakeDynamic()); }

#define HANDLER(name) name

#endif  // PHYS_STUB

napi_value Register(napi_env env, napi_value exports)
{
#define D(js, fn) {js, nullptr, HANDLER(fn), nullptr, nullptr, nullptr, napi_default, nullptr}
    napi_property_descriptor desc[] = {
        D("physInit", PhysInit),
        D("physReset", PhysReset),
        D("physSetGravity", PhysSetGravity),
        D("physSetBound", PhysSetBound),
        D("physAddBox", PhysAddBox),
        D("physAddSphere", PhysAddSphere),
        D("physAddCylinder", PhysAddCylinder),
        D("physAddParts", PhysAddParts),
        D("physRemove", PhysRemove),
        D("physSetPose", PhysSetPose),
        D("physSetMaterial", PhysSetMaterial),
        D("physSetVelocity", PhysSetVelocity),
        D("physSleep", PhysSleep),
        D("physMoveKinematic", PhysMoveKinematic),
        D("physStep", PhysStep),
        D("physStepBegin", PhysStepBegin),
        D("physStepEnd", PhysStepEnd),
        D("physReadAwake", PhysReadAwake),
        D("physReadPose", PhysReadPose),
        D("physDrainContacts", PhysDrainContacts),
        D("physAwakeDynamic", PhysAwakeDynamic),
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

}  // namespace

EXTERN_C_START
static napi_module g_module = {
    .nm_version = 1, .nm_flags = 0, .nm_filename = nullptr, .nm_register_func = Register,
    .nm_modname = "phys", .nm_priv = nullptr, .reserved = {nullptr},
};
__attribute__((constructor)) void RegisterPhys(void) { napi_module_register(&g_module); }
EXTERN_C_END
