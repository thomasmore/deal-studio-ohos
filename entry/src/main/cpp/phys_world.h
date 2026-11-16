// PhysWorld: a small rigid-body world over Jolt Physics, with no NAPI and no logging, so the
// host test (tools/phys-world-test.cpp) builds the same code the phone runs.
//
// Units are metres, seconds and kilograms; quaternions are x, y, z, w; y is up. A body is named
// by a dense index that is reused after remove(). Bodies are static (0), dynamic (1) or
// kinematic (2). Nothing here is thread-safe except the contact buffer: call it from one thread.
#pragma once

#include <Jolt/Jolt.h>
#include <Jolt/RegisterTypes.h>
#include <Jolt/Core/Factory.h>
#include <Jolt/Core/TempAllocator.h>
#include <Jolt/Core/JobSystemThreadPool.h>
#include <Jolt/Physics/PhysicsSettings.h>
#include <Jolt/Physics/PhysicsSystem.h>
#include <Jolt/Physics/Collision/ContactListener.h>
#include <Jolt/Physics/Collision/Shape/BoxShape.h>
#include <Jolt/Physics/Collision/Shape/SphereShape.h>
#include <Jolt/Physics/Collision/Shape/CylinderShape.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

JPH_SUPPRESS_WARNINGS

namespace vphys {

enum Kind { kStatic = 0, kDynamic = 1, kKinematic = 2 };

namespace layers {
constexpr JPH::ObjectLayer kNonMoving = 0;
constexpr JPH::ObjectLayer kMoving = 1;
}  // namespace layers

class PairFilter : public JPH::ObjectLayerPairFilter {
public:
    bool ShouldCollide(JPH::ObjectLayer a, JPH::ObjectLayer b) const override
    {
        return a == layers::kMoving || b == layers::kMoving;
    }
};

class BroadPhaseMap final : public JPH::BroadPhaseLayerInterface {
public:
    JPH::uint GetNumBroadPhaseLayers() const override { return 2; }
    JPH::BroadPhaseLayer GetBroadPhaseLayer(JPH::ObjectLayer l) const override
    {
        return JPH::BroadPhaseLayer(l == layers::kNonMoving ? 0 : 1);
    }
#if defined(JPH_EXTERNAL_PROFILE) || defined(JPH_PROFILE_ENABLED)
    const char *GetBroadPhaseLayerName(JPH::BroadPhaseLayer) const override { return "layer"; }
#endif
};

class ObjectVsBroadPhase : public JPH::ObjectVsBroadPhaseLayerFilter {
public:
    bool ShouldCollide(JPH::ObjectLayer l, JPH::BroadPhaseLayer b) const override
    {
        return l == layers::kMoving || b == JPH::BroadPhaseLayer(1);
    }
};

// How many floats a Float32Array argument may be written with. OpenHarmony's napi_get_typedarray_info
// reports the view's length in BYTES (native_api.cpp: `*length = typedArray->ByteLength(vm)`), where
// Node reports elements, so its `reported` length alone is four times too much for a Float32Array:
// sizing a write by it ran drainContacts 9 KB past a 3 KB buffer during a wall's collapse and
// corrupted ArkUI's heap (SIGSEGV in FrameNode::Layout with contact pairs for pointers). The
// count is the array's own JS `length` (elements on every engine), never more than either the
// reported length or what the backing ArrayBuffer holds past the view's offset. A length that is
// not a finite non-negative number gives 0: write nothing.
inline size_t FloatCapacity(double jsLength, size_t reported, size_t bufferBytes, size_t byteOffset)
{
    if (!(jsLength >= 0) || !std::isfinite(jsLength) || byteOffset > bufferBytes) {
        return 0;
    }
    size_t n = static_cast<size_t>(jsLength);
    n = std::min(n, reported);
    n = std::min(n, (bufferBytes - byteOffset) / sizeof(float));
    return n;
}

// Jolt's allocator and type registry are process-wide: set them up once.
inline void JoltOnce()
{
    static bool done = false;
    if (!done) {
        JPH::RegisterDefaultAllocator();
        JPH::Factory::sInstance = new JPH::Factory();
        JPH::RegisterTypes();
        done = true;
    }
}

class PhysWorld {
public:
    PhysWorld() = default;
    PhysWorld(const PhysWorld &) = delete;
    PhysWorld &operator=(const PhysWorld &) = delete;
    ~PhysWorld() { Release(); }

    // Builds the world. threads is the number of extra worker threads (0 = the caller alone, which
    // is what the deterministic host test uses). Returns false if already built or on failure.
    bool init(int maxBodies, int threads)
    {
        if (system_) {
            return false;
        }
        JoltOnce();
        maxBodies = std::max(maxBodies, 16);
        temp_ = std::make_unique<JPH::TempAllocatorImpl>(10 * 1024 * 1024);
        jobs_ = std::make_unique<JPH::JobSystemThreadPool>(JPH::cMaxPhysicsJobs, JPH::cMaxPhysicsBarriers,
                                                           std::max(threads, 0));
        system_ = std::make_unique<JPH::PhysicsSystem>();
        JPH::uint pairs = static_cast<JPH::uint>(std::max(maxBodies * 8, 4096));
        system_->Init(static_cast<JPH::uint>(maxBodies), 0, pairs, pairs, bpMap_, objVsBp_, pairFilter_);
        JPH::PhysicsSettings ps = system_->GetPhysicsSettings();
        ps.mPenetrationSlop = 0.002f;  // dice are centimetres, the default 2 cm would sink them
        system_->SetPhysicsSettings(ps);
        system_->SetGravity(JPH::Vec3(0, -9.81f, 0));
        system_->SetContactListener(&contacts_);
        return true;
    }

    bool ready() const { return system_ != nullptr; }

    // Removes every body and clears the bound-reset, contact and sleep-cap state.
    void reset()
    {
        if (!system_) {
            return;
        }
        for (size_t i = 0; i < bodies_.size(); i++) {
            if (bodies_[i].alive) {
                Destroy(bodies_[i]);
            }
        }
        bodies_.clear();
        free_.clear();
        reported_.clear();
        lastActive_.clear();
        contacts_.clear();
    }

    void setGravity(float y)
    {
        if (system_) {
            system_->SetGravity(JPH::Vec3(0, y, 0));
        }
    }

    // A dynamic body below minY, or beyond +-halfX / +-halfZ, goes back to its creation pose.
    void setBound(float minY, float halfX, float halfZ)
    {
        minY_ = minY;
        halfX_ = halfX;
        halfZ_ = halfZ;
    }

    int addBox(float hx, float hy, float hz, int kind)
    {
        float minHalf = std::min(hx, std::min(hy, hz));
        return Add(new JPH::BoxShape(JPH::Vec3(hx, hy, hz), std::min(0.05f, 0.2f * minHalf)), kind);
    }
    int addSphere(float r, int kind) { return Add(new JPH::SphereShape(r), kind); }
    int addCylinder(float r, float halfHeight, int kind)
    {
        float convex = std::min(0.05f, 0.2f * std::min(r, halfHeight));
        return Add(new JPH::CylinderShape(halfHeight, r, convex), kind);
    }

    void remove(int i)
    {
        if (!Valid(i)) {
            return;
        }
        Destroy(bodies_[i]);
        bodies_[i].alive = false;
        free_.push_back(i);
    }

    // Places a body (teleport). This pose also becomes the one the world bound resets it to.
    void setPose(int i, float px, float py, float pz, float qx, float qy, float qz, float qw)
    {
        if (!Valid(i)) {
            return;
        }
        Slot &s = bodies_[i];
        JPH::Quat q = JPH::Quat(qx, qy, qz, qw).Normalized();
        s.home[0] = px; s.home[1] = py; s.home[2] = pz;
        s.home[3] = q.GetX(); s.home[4] = q.GetY(); s.home[5] = q.GetZ(); s.home[6] = q.GetW();
        BI().SetPositionAndRotation(s.id, JPH::RVec3(px, py, pz), q,
                                    s.kind == kStatic ? JPH::EActivation::DontActivate : JPH::EActivation::Activate);
        s.awakeFor = 0;
    }

    // Mass applies to dynamic bodies only (inertia is rescaled with it).
    void setMaterial(int i, float mass, float restitution, float friction)
    {
        if (!Valid(i)) {
            return;
        }
        Slot &s = bodies_[i];
        BI().SetRestitution(s.id, restitution);
        BI().SetFriction(s.id, friction);
        if (s.kind == kDynamic && mass > 0) {
            JPH::Body *b = system_->GetBodyLockInterfaceNoLock().TryGetBody(s.id);
            if (b && b->GetMotionProperties()) {
                b->GetMotionProperties()->ScaleToMass(mass);
            }
        }
    }

    // Sets both velocities and wakes the body; restarts its 8 s sleep cap.
    void setVelocity(int i, float vx, float vy, float vz, float wx, float wy, float wz)
    {
        if (!Valid(i)) {
            return;
        }
        BI().SetLinearAndAngularVelocity(bodies_[i].id, JPH::Vec3(vx, vy, vz), JPH::Vec3(wx, wy, wz));
        BI().ActivateBody(bodies_[i].id);
        bodies_[i].awakeFor = 0;
    }

    // Puts a dynamic body to sleep where it is, as if it had come to rest there: it stays put until
    // something awake touches it, setVelocity or setPose wakes it. A stack built resting starts
    // like this, so it stands until hit instead of settling (and, for a tall one, falling) by itself.
    void sleep(int i)
    {
        if (!Valid(i) || bodies_[i].kind != kDynamic) {
            return;
        }
        BI().SetLinearAndAngularVelocity(bodies_[i].id, JPH::Vec3::sZero(), JPH::Vec3::sZero());
        BI().DeactivateBody(bodies_[i].id);
    }

    // Moves a kinematic body to the pose over dt seconds (it pushes what it touches).
    void moveKinematic(int i, float px, float py, float pz, float qx, float qy, float qz, float qw, float dt)
    {
        if (!Valid(i) || bodies_[i].kind != kKinematic) {
            return;
        }
        BI().MoveKinematic(bodies_[i].id, JPH::RVec3(px, py, pz), JPH::Quat(qx, qy, qz, qw).Normalized(),
                           std::max(dt, 1e-4f));
    }

    void step(float dt, int substeps)
    {
        if (!system_ || dt <= 0) {
            return;
        }
        system_->Update(dt, std::max(substeps, 1), temp_.get(), jobs_.get());
        std::vector<int> moved;
        ApplyBound(moved);
        // The sleep cap is per body: one awake for kSleepCapSeconds in a row (jittering, or kept
        // awake by a neighbour that never rests) is put to sleep. Its time restarts whenever it
        // sleeps or is placed, created or kicked, so a new body or one woken by a push still moves.
        for (size_t i = 0; i < bodies_.size(); i++) {
            Slot &s = bodies_[i];
            if (!s.alive || s.kind != kDynamic) {
                continue;
            }
            if (!BI().IsActive(s.id)) {
                s.awakeFor = 0;
            } else if ((s.awakeFor += dt) > kSleepCapSeconds) {
                BI().DeactivateBody(s.id);
                s.awakeFor = 0;
            }
        }
        // Report what is active now, what was active a step ago (its final pose), and what was reset.
        JPH::BodyIDVector active;
        system_->GetActiveBodies(JPH::EBodyType::RigidBody, active);
        std::vector<int> now;
        reported_.clear();
        std::vector<uint8_t> seen(bodies_.size(), 0);
        auto add = [&](int idx) {
            if (idx >= 0 && static_cast<size_t>(idx) < bodies_.size() && bodies_[idx].alive && !seen[idx]) {
                seen[idx] = 1;
                reported_.push_back(idx);
            }
        };
        for (const JPH::BodyID &id : active) {
            int idx = IndexOf(id);
            if (idx >= 0) {
                now.push_back(idx);
                add(idx);
            }
        }
        for (int idx : lastActive_) { add(idx); }
        for (int idx : moved) { add(idx); }
        lastActive_ = std::move(now);
    }

    // [index, px,py,pz, qx,qy,qz,qw] for each body that moved in the last step, up to cap bodies.
    int readAwake(float *out, int cap) const
    {
        if (!system_) {
            return 0;
        }
        int n = 0;
        for (int idx : reported_) {
            if (n >= cap) {
                break;
            }
            if (static_cast<size_t>(idx) < bodies_.size() && bodies_[idx].alive) {
                float *o = out + static_cast<size_t>(n) * 8;
                o[0] = static_cast<float>(idx);
                ReadPose(idx, o + 1);
                n++;
            }
        }
        return n;
    }

    bool readPose(int i, float *out7) const
    {
        if (!Valid(i)) {
            return false;
        }
        ReadPose(i, out7);
        return true;
    }

    // Triples [a, b, approachSpeed] of contacts begun since the last drain; at most cap triples.
    // What the buffer could not hold is counted in droppedContacts().
    int drainContacts(float *out, int cap) { return contacts_.drain(out, cap); }
    uint32_t droppedContacts() const { return contacts_.dropped(); }

    int awakeDynamic() const
    {
        if (!system_) {
            return 0;
        }
        JPH::BodyIDVector active;
        system_->GetActiveBodies(JPH::EBodyType::RigidBody, active);
        int n = 0;
        for (const JPH::BodyID &id : active) {
            int idx = IndexOf(id);
            if (idx >= 0 && bodies_[idx].kind == kDynamic) {
                n++;
            }
        }
        return n;
    }

private:
    static constexpr float kSleepCapSeconds = 8.0f;
    static constexpr size_t kContactCap = 1024;

    struct Slot {
        JPH::BodyID id;
        int kind = 0;
        bool alive = false;
        float awakeFor = 0;  // seconds awake in a row, for the sleep cap
        float home[7] = {0, 0, 0, 0, 0, 0, 1};
    };

    class Contacts : public JPH::ContactListener {
    public:
        void OnContactAdded(const JPH::Body &b1, const JPH::Body &b2, const JPH::ContactManifold &m,
                            JPH::ContactSettings &) override
        {
            JPH::RVec3 p = m.GetWorldSpaceContactPointOn1(0);
            float speed = (b1.GetPointVelocity(p) - b2.GetPointVelocity(p)).Dot(m.mWorldSpaceNormal);
            std::lock_guard<std::mutex> lock(mutex_);
            if (items_.size() >= kContactCap) {
                dropped_++;
                return;
            }
            items_.push_back({static_cast<float>(b1.GetUserData()), static_cast<float>(b2.GetUserData()),
                              std::fabs(speed)});
        }
        int drain(float *out, int cap)
        {
            std::lock_guard<std::mutex> lock(mutex_);
            int n = static_cast<int>(std::min(items_.size(), static_cast<size_t>(std::max(cap, 0))));
            for (int i = 0; i < n; i++) {
                out[i * 3] = items_[i].a;
                out[i * 3 + 1] = items_[i].b;
                out[i * 3 + 2] = items_[i].speed;
            }
            dropped_ += static_cast<uint32_t>(items_.size() - n);
            items_.clear();
            return n;
        }
        uint32_t dropped() const
        {
            std::lock_guard<std::mutex> lock(mutex_);
            return dropped_;
        }
        void clear()
        {
            std::lock_guard<std::mutex> lock(mutex_);
            items_.clear();
            dropped_ = 0;
        }

    private:
        struct Item { float a, b, speed; };
        mutable std::mutex mutex_;
        std::vector<Item> items_;
        uint32_t dropped_ = 0;
    };

    JPH::BodyInterface &BI() { return system_->GetBodyInterfaceNoLock(); }
    const JPH::BodyInterface &BI() const { return system_->GetBodyInterfaceNoLock(); }
    bool Valid(int i) const
    {
        return system_ && i >= 0 && static_cast<size_t>(i) < bodies_.size() && bodies_[i].alive;
    }
    int IndexOf(const JPH::BodyID &id) const
    {
        const JPH::Body *b = system_->GetBodyLockInterfaceNoLock().TryGetBody(id);
        return b ? static_cast<int>(b->GetUserData()) : -1;
    }
    void ReadPose(int i, float *o) const
    {
        JPH::RVec3 p;
        JPH::Quat q;
        BI().GetPositionAndRotation(bodies_[i].id, p, q);
        o[0] = static_cast<float>(p.GetX()); o[1] = static_cast<float>(p.GetY()); o[2] = static_cast<float>(p.GetZ());
        o[3] = q.GetX(); o[4] = q.GetY(); o[5] = q.GetZ(); o[6] = q.GetW();
    }
    void Destroy(Slot &s)
    {
        BI().RemoveBody(s.id);
        BI().DestroyBody(s.id);
    }

    int Add(JPH::Shape *shape, int kind)
    {
        if (!system_) {
            return -1;
        }
        kind = std::max(0, std::min(kind, 2));
        JPH::EMotionType mt = kind == kStatic ? JPH::EMotionType::Static
            : kind == kDynamic ? JPH::EMotionType::Dynamic : JPH::EMotionType::Kinematic;
        JPH::BodyCreationSettings s(shape, JPH::RVec3(0, 0, 0), JPH::Quat::sIdentity(), mt,
                                    kind == kStatic ? layers::kNonMoving : layers::kMoving);
        s.mLinearDamping = 0.05f;
        s.mAngularDamping = 0.3f;
        s.mRestitution = 0.3f;
        s.mFriction = 0.5f;
        JPH::Body *body = BI().CreateBody(s);
        if (!body) {
            return -1;
        }
        int idx;
        if (!free_.empty()) {
            idx = free_.back();
            free_.pop_back();
        } else {
            idx = static_cast<int>(bodies_.size());
            bodies_.emplace_back();
        }
        body->SetUserData(static_cast<JPH::uint64>(idx));
        BI().AddBody(body->GetID(), JPH::EActivation::DontActivate);
        Slot &slot = bodies_[idx];
        slot.id = body->GetID();
        slot.kind = kind;
        slot.alive = true;
        slot.awakeFor = 0;
        const float home[7] = {0, 0, 0, 0, 0, 0, 1};
        std::copy(home, home + 7, slot.home);
        if (kind == kDynamic) {
            BI().ActivateBody(slot.id);
        }
        return idx;
    }

    void ApplyBound(std::vector<int> &moved)
    {
        for (size_t i = 0; i < bodies_.size(); i++) {
            Slot &s = bodies_[i];
            if (!s.alive || s.kind != kDynamic) {
                continue;
            }
            JPH::RVec3 p = BI().GetPosition(s.id);
            float x = static_cast<float>(p.GetX()), y = static_cast<float>(p.GetY()), z = static_cast<float>(p.GetZ());
            if (y < minY_ || std::fabs(x) > halfX_ || std::fabs(z) > halfZ_ || !std::isfinite(x + y + z)) {
                BI().SetPositionAndRotation(s.id, JPH::RVec3(s.home[0], s.home[1], s.home[2]),
                                            JPH::Quat(s.home[3], s.home[4], s.home[5], s.home[6]),
                                            JPH::EActivation::Activate);
                BI().SetLinearAndAngularVelocity(s.id, JPH::Vec3::sZero(), JPH::Vec3::sZero());
                moved.push_back(static_cast<int>(i));
            }
        }
    }

    void Release()
    {
        if (system_) {
            reset();
            system_.reset();
        }
        jobs_.reset();
        temp_.reset();
    }

    BroadPhaseMap bpMap_;
    ObjectVsBroadPhase objVsBp_;
    PairFilter pairFilter_;
    Contacts contacts_;
    std::unique_ptr<JPH::TempAllocatorImpl> temp_;
    std::unique_ptr<JPH::JobSystemThreadPool> jobs_;
    std::unique_ptr<JPH::PhysicsSystem> system_;
    std::vector<Slot> bodies_;
    std::vector<int> free_;
    std::vector<int> reported_;
    std::vector<int> lastActive_;
    float minY_ = -50.0f;
    float halfX_ = 100.0f;
    float halfZ_ = 100.0f;
};

}  // namespace vphys
