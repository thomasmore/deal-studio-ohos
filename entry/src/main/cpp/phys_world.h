// PhysWorld: a small rigid-body world over Jolt Physics, with no NAPI and no logging, so the
// host test (tools/phys-world-test.cpp) builds the same code the phone runs.
//
// Units are metres, seconds and kilograms; quaternions are x, y, z, w; y is up. A body is named
// by a dense index that is reused after remove(). Bodies are static (0), dynamic (1), kinematic (2)
// or a character (3): a dynamic body that stays upright, turns only about y and is driven (drive()).
// Nothing here is thread-safe except the contact buffer: call it from one thread.
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
#include <Jolt/Physics/Collision/Shape/ConvexHullShape.h>
#include <Jolt/Physics/Collision/Shape/StaticCompoundShape.h>
#include <Jolt/Physics/Body/BodyCreationSettings.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

JPH_SUPPRESS_WARNINGS

namespace vphys {

enum Kind { kStatic = 0, kDynamic = 1, kKinematic = 2, kCharacter = 3 };

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
        touching_.reset(new std::atomic<uint8_t>[maxBodies]);
        touchCount_ = static_cast<size_t>(maxBodies);
        for (size_t i = 0; i < touchCount_; i++) {
            touching_[i].store(0, std::memory_order_relaxed);
        }
        contacts_.setTouching(touching_.get(), touchCount_);
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
    int addSphere(float r, int kind) { return Add(new JPH::SphereShape(r), kind, true); }
    int addCylinder(float r, float halfHeight, int kind)
    {
        float convex = std::min(0.05f, 0.2f * std::min(r, halfHeight));
        return Add(new JPH::CylinderShape(halfHeight, r, convex), kind, true);
    }

    // A body of any shape: count records of kPartRecord floats, [type, px, py, pz, qx, qy, qz, qw, a, b, c, n], each
    // one convex part placed at p and turned by q about the body's origin: type 0 a box of half-extents a, b, c; 1 a
    // sphere of radius a; 2 a cylinder along y of radius a and half-height b; 3 the convex hull of the next n points
    // (x, y, z after x, y, z) of points, which holds pointFloats numbers. Several are joined in a static compound (Jolt
    // finds its centre of mass and inertia). Returns its
    // index, or -1: no parts or more than kMaxParts, an unknown type, a size not above 0, a hull of fewer than 4 or more
    // than kMaxHullPoints points, points past the end, or no volume.
    int addParts(const float *records, int count, const float *points, size_t pointFloats, int kind)
    {
        if (!system_ || records == nullptr || count <= 0 || count > kMaxParts) {
            return -1;
        }
        std::vector<JPH::RefConst<JPH::Shape>> parts;
        std::vector<JPH::Vec3> at;
        std::vector<JPH::Quat> turn;
        size_t used = 0;
        bool round = false;
        for (int k = 0; k < count; k++) {
            const float *r = records + static_cast<size_t>(k) * kPartRecord;
            for (int j = 0; j < kPartRecord; j++) {
                if (!std::isfinite(r[j])) {
                    return -1;
                }
            }
            int type = static_cast<int>(r[0]);
            float a = r[8], b = r[9], c = r[10];
            round = round || type == 1 || type == 2;
            JPH::RefConst<JPH::Shape> shape;
            if (type == 0) {
                if (!(a > 0 && b > 0 && c > 0)) {
                    return -1;
                }
                shape = new JPH::BoxShape(JPH::Vec3(a, b, c), std::min(0.05f, 0.2f * std::min(a, std::min(b, c))));
            } else if (type == 1) {
                if (!(a > 0)) {
                    return -1;
                }
                shape = new JPH::SphereShape(a);
            } else if (type == 2) {
                if (!(a > 0 && b > 0)) {
                    return -1;
                }
                shape = new JPH::CylinderShape(b, a, std::min(0.05f, 0.2f * std::min(a, b)));
            } else if (type == 3) {
                int n = static_cast<int>(r[11]);
                if (points == nullptr || n < 4 || n > kMaxHullPoints || used + static_cast<size_t>(n) * 3 > pointFloats) {
                    return -1;
                }
                shape = Hull(points + used, n);
                used += static_cast<size_t>(n) * 3;
                if (shape == nullptr) {
                    return -1;
                }
            } else {
                return -1;
            }
            parts.push_back(shape);
            at.push_back(JPH::Vec3(r[1], r[2], r[3]));
            turn.push_back(JPH::Quat(r[4], r[5], r[6], r[7]).Normalized());
        }
        // One part at the origin, unturned, comes back as itself; one moved or turned as a RotatedTranslatedShape.
        JPH::StaticCompoundShapeSettings compound;
        for (size_t k = 0; k < parts.size(); k++) {
            compound.AddShape(at[k], turn[k], parts[k]);
        }
        JPH::ShapeSettings::ShapeResult made = compound.Create();
        if (made.HasError()) {
            return -1;
        }
        return Add(made.Get(), kind, round);
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

    // Mass applies to dynamic bodies only (inertia is rescaled with it). A character neither bounces nor grips: its
    // speed is the one drive() gives it, and friction would eat into that on every substep.
    void setMaterial(int i, float mass, float restitution, float friction)
    {
        if (!Valid(i)) {
            return;
        }
        Slot &s = bodies_[i];
        BI().SetRestitution(s.id, s.character ? 0.0f : restitution);
        BI().SetFriction(s.id, s.character ? 0.0f : friction);
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

    // Drives a character: its velocity along the ground (vx, vz) and its turn about y (wy, radians a second); its
    // vertical velocity is its own, so it falls, lands and jumps as before. Wakes it and restarts its sleep cap; a
    // character left undriven at rest sleeps as any body does.
    void drive(int i, float vx, float vz, float wy)
    {
        if (!Valid(i) || !bodies_[i].character) {
            return;
        }
        JPH::BodyID id = bodies_[i].id;
        float vy = BI().GetLinearVelocity(id).GetY();
        BI().SetLinearAndAngularVelocity(id, JPH::Vec3(vx, vy, vz), JPH::Vec3(0, wy, 0));
        if (vx != 0 || vz != 0 || wy != 0) {
            BI().ActivateBody(id);
        }
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
        for (size_t i = 0; i < touchCount_; i++) {
            touching_[i].store(0, std::memory_order_relaxed);
        }
        system_->Update(dt, std::max(substeps, 1), temp_.get(), jobs_.get());
        RollingResistance(dt);
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
            // A character is the person's to move: one walking about never keeps a throw from settling.
            if (idx >= 0 && bodies_[idx].kind == kDynamic && !bodies_[idx].character) {
                n++;
            }
        }
        return n;
    }

private:
    static constexpr float kSleepCapSeconds = 8.0f;
    static constexpr size_t kContactCap = 1024;
    // Half-extent below which a moving body is cast along its motion (a sheet 2 cm thick or thinner).
    static constexpr float kThinHalf = 0.01f;
    // Rolling and spinning resistance. Jolt has neither, so a ball rolls on, a snowman on its side rolls in circles and
    // one standing spins on its round foot like a top, each until the sleep cap. A body with a round side, touching
    // something, loses kRollDecel m/s^2 of the speed its surface turns at (its turn times its smallest half-extent),
    // whichever way. A body of flat faces only (a box, a die, a hull) is left alone: friction stops it within a second
    // or so, and slowing its last turn would leave a die leaning on a wall instead of falling flat.
    static constexpr float kRollDecel = 1.0f;

public:
    static constexpr int kMaxHullPoints = 128;
    static constexpr int kMaxParts = 32;
    static constexpr int kPartRecord = 12;

private:

    struct Slot {
        JPH::BodyID id;
        int kind = 0;
        bool alive = false;
        float awakeFor = 0;  // seconds awake in a row, for the sleep cap
        bool rolls = false;  // has a round side: a sphere, a cylinder, or parts with one of them
        bool character = false;  // driven (kCharacter at creation): upright, turning about y only
        float rollRadius = 0.05f;  // its smallest half-extent: how far its surface is from its centre, for rolling
        float home[7] = {0, 0, 0, 0, 0, 0, 1};
    };

    class Contacts : public JPH::ContactListener {
    public:
        void OnContactAdded(const JPH::Body &b1, const JPH::Body &b2, const JPH::ContactManifold &m,
                            JPH::ContactSettings &) override
        {
            Touch(b1, b2);
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
        void OnContactPersisted(const JPH::Body &b1, const JPH::Body &b2, const JPH::ContactManifold &,
                                JPH::ContactSettings &) override
        {
            Touch(b1, b2);
        }
        // Where the bodies touching in this step are marked, one flag per body index (called from the job threads).
        void setTouching(std::atomic<uint8_t> *flags, size_t count)
        {
            touching_ = flags;
            touchCount_ = count;
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
        void Touch(const JPH::Body &b1, const JPH::Body &b2)
        {
            for (JPH::uint64 i : {b1.GetUserData(), b2.GetUserData()}) {
                if (i < touchCount_) {
                    touching_[i].store(1, std::memory_order_relaxed);
                }
            }
        }
        std::atomic<uint8_t> *touching_ = nullptr;
        size_t touchCount_ = 0;
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

    // The convex hull of n points (x, y, z after x, y, z), rounded as a box is; null when Jolt refuses it or it has no
    // volume (Jolt makes a flat hull of points in one plane; a body needs a cubic millimetre at least).
    static JPH::RefConst<JPH::Shape> Hull(const float *v, int n)
    {
        JPH::Array<JPH::Vec3> points;
        float lo[3] = {INFINITY, INFINITY, INFINITY};
        float hi[3] = {-INFINITY, -INFINITY, -INFINITY};
        for (int j = 0; j < n; j++) {
            const float *p = v + static_cast<size_t>(j) * 3;
            for (int c = 0; c < 3; c++) {
                lo[c] = std::min(lo[c], p[c]);
                hi[c] = std::max(hi[c], p[c]);
            }
            points.push_back(JPH::Vec3(p[0], p[1], p[2]));
        }
        float minHalf = 0.5f * std::min(hi[0] - lo[0], std::min(hi[1] - lo[1], hi[2] - lo[2]));
        JPH::ConvexHullShapeSettings hull(points, std::min(0.05f, 0.2f * minHalf));
        JPH::ShapeSettings::ShapeResult made = hull.Create();
        if (made.HasError() || made.Get()->GetVolume() < 1e-9f) {
            return nullptr;
        }
        return made.Get();
    }

    // rolls: the shape has a round side (a sphere or cylinder in it), so it gets rolling resistance.
    int Add(const JPH::Shape *shape, int kind, bool rolls = false)
    {
        if (!system_) {
            return -1;
        }
        kind = std::max(0, std::min(kind, 3));
        bool character = kind == kCharacter;
        if (character) {
            kind = kDynamic;
        }
        JPH::EMotionType mt = kind == kStatic ? JPH::EMotionType::Static
            : kind == kDynamic ? JPH::EMotionType::Dynamic : JPH::EMotionType::Kinematic;
        JPH::BodyCreationSettings s(shape, JPH::RVec3(0, 0, 0), JPH::Quat::sIdentity(), mt,
                                    kind == kStatic ? layers::kNonMoving : layers::kMoving);
        s.mLinearDamping = 0.05f;
        s.mAngularDamping = 0.3f;
        s.mRestitution = 0.3f;
        s.mFriction = 0.5f;
        if (character) {
            // Upright whatever hits it, turning only about y; cast along its motion so a quick one does not pass
            // through a thin wall.
            s.mAllowedDOFs = JPH::EAllowedDOFs::TranslationX | JPH::EAllowedDOFs::TranslationY |
                JPH::EAllowedDOFs::TranslationZ | JPH::EAllowedDOFs::RotationY;
            s.mRestitution = 0;
            s.mFriction = 0;
            s.mAngularDamping = 0;
            s.mMotionQuality = JPH::EMotionQuality::LinearCast;
            rolls = false;
        }
        // A thin moving body (a sheet, a coin) can pass most of its thickness into the ground in one step, deeper than
        // the penetration slop pushes back out of: cast it along its motion instead (Jolt's continuous collision).
        if (kind != kStatic) {
            JPH::Vec3 extent = shape->GetLocalBounds().GetExtent();
            if (std::min(extent.GetX(), std::min(extent.GetY(), extent.GetZ())) < kThinHalf) {
                s.mMotionQuality = JPH::EMotionQuality::LinearCast;
            }
        }
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
        slot.rolls = rolls;
        slot.character = character;
        JPH::Vec3 extent = shape->GetLocalBounds().GetExtent();
        slot.rollRadius = std::max(0.005f, std::min(extent.GetX(), std::min(extent.GetY(), extent.GetZ())));
        const float home[7] = {0, 0, 0, 0, 0, 0, 1};
        std::copy(home, home + 7, slot.home);
        if (kind == kDynamic) {
            BI().ActivateBody(slot.id);
        }
        return idx;
    }

    void RollingResistance(float dt)
    {
        for (size_t i = 0; i < bodies_.size() && i < touchCount_; i++) {
            Slot &s = bodies_[i];
            if (!s.alive || s.kind != kDynamic || !s.rolls || !touching_[i].load(std::memory_order_relaxed) || !BI().IsActive(s.id)) {
                continue;
            }
            JPH::Vec3 w = BI().GetAngularVelocity(s.id);
            float turn = w.Length();
            if (turn <= 0) {
                continue;
            }
            float left = std::max(0.0f, turn - kRollDecel / s.rollRadius * dt);
            BI().SetAngularVelocity(s.id, w * (left / turn));
        }
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
    std::unique_ptr<std::atomic<uint8_t>[]> touching_;  // per body index: touched something in the step under way
    size_t touchCount_ = 0;
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
