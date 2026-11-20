// Host test for the physics world (entry/src/main/cpp/phys_world.h), single thread, against the
// same Jolt sources the phone build uses (fetch them first: see the top of
// entry/src/main/cpp/CMakeLists.txt).
//
//   cmake -S tools/phys-world-test -B /tmp/phys-world-test-build -DCMAKE_BUILD_TYPE=Release
//   cmake --build /tmp/phys-world-test-build -j && /tmp/phys-world-test-build/phys_world_test

#include "phys_world.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace {

int g_failures = 0;

void Check(bool ok, const char *what)
{
    std::printf("%s: %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        g_failures++;
    }
}

constexpr float kDt = 1.0f / 60.0f;
constexpr int kRec = vphys::PhysWorld::kContactRecord;

// A contact record [a, b, speed, px, py, pz] between bodies x and y, either way round.
bool Pair(const float *r, int x, int y)
{
    float fx = static_cast<float>(x), fy = static_cast<float>(y);
    return (r[0] == fx && r[1] == fy) || (r[0] == fy && r[1] == fx);
}
bool Has(const float *r, int x) { return r[0] == static_cast<float>(x) || r[1] == static_cast<float>(x); }

// A floor whose top face is y = 0.
int Floor(vphys::PhysWorld &w)
{
    int f = w.addBox(20, 0.5f, 20, vphys::kStatic);
    w.setPose(f, 0, -0.5f, 0, 0, 0, 0, 1);
    return f;
}

void TestRest()
{
    vphys::PhysWorld w;
    w.init(64, 0);
    Floor(w);
    int b = w.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
    w.setPose(b, 0, 0.5f, 0, 0, 0, 0, 1);
    int steps = 0;
    while (steps < 600 && (steps < 10 || w.awakeDynamic() > 0)) {
        w.step(kDt, 1);
        steps++;
    }
    float p[7];
    w.readPose(b, p);
    std::printf("      rest y = %.5f after %d steps, awake dynamic %d\n", p[1], steps, w.awakeDynamic());
    Check(std::fabs(p[1] - 0.05f) < 0.001f, "box rests at half-height +-1 mm");
    Check(w.awakeDynamic() == 0 && steps < 600, "box goes to sleep");
    // A kick on a sleeping body (a throw of dice lying still) wakes it before the next step.
    w.setVelocity(b, 0, 2, 0, 3, 0, 0);
    Check(w.awakeDynamic() == 1, "setVelocity wakes a sleeping body at once");
    w.step(kDt, 1);
    w.readPose(b, p);
    Check(p[1] > 0.06f && w.awakeDynamic() == 1, "and it moves on the next step");
}

void TestBound()
{
    vphys::PhysWorld w;
    w.init(64, 0);
    Floor(w);
    w.setBound(-5, 3, 3);
    int b = w.addSphere(0.1f, vphys::kDynamic);
    w.setPose(b, 0, 1, 0, 0, 0, 0, 1);
    w.setVelocity(b, 30, 0, 0, 0, 0, 0);  // gone through the x wall within a second
    bool reset = false;
    std::vector<float> out(8 * 8);
    for (int i = 0; i < 120 && !reset; i++) {
        w.step(kDt, 1);
        float p[7];
        w.readPose(b, p);
        reset = std::fabs(p[0]) < 1e-4f && std::fabs(p[1] - 1) < 1e-4f && std::fabs(p[2]) < 1e-4f;
        if (reset) {
            int n = w.readAwake(out.data(), 8);
            bool listed = false;
            for (int k = 0; k < n; k++) { listed = listed || out[k * 8] == static_cast<float>(b); }
            Check(listed, "the reset body is reported by readAwake");
        }
    }
    Check(reset, "a body thrown out of bounds is back at its creation pose");
}

void TestContacts()
{
    vphys::PhysWorld w;
    w.init(64, 0);
    int f = Floor(w);
    int b = w.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
    w.setPose(b, 0, 1, 0, 0, 0, 0, 1);
    float all[kRec * 64];
    int total = 0;
    float speed = 0;
    bool pair = false;
    for (int i = 0; i < 90; i++) {
        w.step(kDt, 1);
        int n = w.drainContacts(all, 64);
        for (int k = 0; k < n; k++) {
            const float *r = all + k * kRec;
            total++;
            speed = std::max(speed, r[2]);
            pair = pair || Pair(r, b, f);
        }
    }
    std::printf("      %d contacts, max approach %.2f m/s (free fall from 0.95 m: 4.32)\n", total, speed);
    Check(total > 0 && pair, "a drop reports a contact between the box and the floor");
    Check(speed > 3.0f && speed < 5.0f, "approach speed is about the fall speed");
}

// The wall of tools/vera-harness/examples/world-cubes.vera as WorldSim builds it: a 10x10 wall of
// 9.8 cm cubes, 2 mm apart, 0.2 kg, on the wide floor slab. Returns the cubes' indices.
std::vector<int> Wall(vphys::PhysWorld &w, bool asleep)
{
    int f = w.addBox(100, 0.5f, 100, vphys::kStatic);
    w.setPose(f, 0, -0.5f, 0, 0, 0, 0, 1);
    w.setMaterial(f, 0, 0.3f, 0.6f);
    std::vector<int> ids;
    for (int row = 0; row < 10; row++) {
        for (int col = 0; col < 10; col++) {
            int b = w.addBox(0.049f, 0.049f, 0.049f, vphys::kDynamic);
            w.setPose(b, (col - 4.5f) * 0.1f, 0.05f + row * 0.1f, 0, 0, 0, 0, 1);
            w.setMaterial(b, 0.2f, 0.3f, 0.6f);
            if (asleep) {
                w.sleep(b);
            }
            ids.push_back(b);
        }
    }
    return ids;
}

// Steps seconds of 60 Hz; returns the largest distance a cube moved from where it started, and
// counts contacts begun faster than 1 m/s (WorldSim's `hit`).
float RunWall(vphys::PhysWorld &w, const std::vector<int> &ids, float seconds, int *hard)
{
    std::vector<float> start;
    for (int b : ids) {
        float p[7];
        w.readPose(b, p);
        start.insert(start.end(), p, p + 3);
    }
    static float buf[kRec * 1024];
    for (int i = 0; i < static_cast<int>(seconds * 60); i++) {
        w.step(kDt, 1);
        int n = w.drainContacts(buf, 1024);
        for (int k = 0; k < n; k++) {
            *hard += buf[k * kRec + 2] > 1.0f ? 1 : 0;
        }
    }
    float most = 0;
    for (size_t j = 0; j < ids.size(); j++) {
        float p[7];
        w.readPose(ids[j], p);
        most = std::max(most, std::hypot(p[0] - start[j * 3], p[1] - start[j * 3 + 1], p[2] - start[j * 3 + 2]));
    }
    return most;
}

void TestWall()
{
    {
        // Awake from the start, Jolt lets a wall this slender settle into its gaps and topple by itself
        // (phone, phase 2: "Hard knocks: 92" before any throw). Printed, not checked: it is why sleep() exists.
        vphys::PhysWorld w;
        w.init(256, 0);
        std::vector<int> ids = Wall(w, false);
        int hard = 0;
        float most = RunWall(w, ids, 5, &hard);
        std::printf("      awake wall: a cube moved %.3f m, %d contacts over 1 m/s\n", most, hard);
    }
    vphys::PhysWorld w;
    w.init(256, 0);
    std::vector<int> ids = Wall(w, true);
    Check(w.awakeDynamic() == 0, "a wall built asleep has nothing awake");
    int hard = 0;
    float most = RunWall(w, ids, 5, &hard);
    std::printf("      asleep wall: a cube moved %.4f m, %d contacts over 1 m/s\n", most, hard);
    Check(most <= 0.001f, "a 10x10 wall built asleep stands still for 5 s (no cube moves > 1 mm)");
    Check(hard == 0, "and nothing knocks over 1 m/s");
    // A ball thrown at it wakes what it hits, and that wakes the rest of the wall it touches.
    int ball = w.addSphere(0.1f, vphys::kDynamic);
    w.setPose(ball, 0, 0.3f, 1.5f, 0, 0, 0, 1);
    w.setMaterial(ball, 3, 0.3f, 0.6f);
    w.setVelocity(ball, 0, 0.5f, -8, 0, 0, 0);
    hard = 0;
    RunWall(w, ids, 3, &hard);
    int knocked = 0;
    for (size_t j = 0; j < ids.size(); j++) {
        float p[7];
        w.readPose(ids[j], p);
        float x = (static_cast<int>(j % 10) - 4.5f) * 0.1f, y = 0.05f + static_cast<int>(j / 10) * 0.1f;
        knocked += std::hypot(p[0] - x, p[1] - y, p[2]) > 0.03f ? 1 : 0;
    }
    std::printf("      the ball knocked %d cubes out of place, %d contacts over 1 m/s\n", knocked, hard);
    Check(knocked >= 10 && hard > 0, "a ball thrown at the sleeping wall knocks it down");
}

std::vector<float> Run()
{
    vphys::PhysWorld w;
    w.init(64, 0);
    Floor(w);
    std::vector<int> ids;
    for (int i = 0; i < 6; i++) {
        int b = i % 2 ? w.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic) : w.addCylinder(0.05f, 0.04f, vphys::kDynamic);
        w.setPose(b, 0.03f * i, 0.3f + 0.12f * i, 0.01f * i, 0.1f * i, 0.2f, 0, 1);
        w.setMaterial(b, 0.1f, 0.4f, 0.6f);
        w.setVelocity(b, 0.5f, 0, -0.3f, 4, 7, 2);
        ids.push_back(b);
    }
    for (int i = 0; i < 240; i++) {
        w.step(kDt, 1);
    }
    std::vector<float> poses;
    for (int b : ids) {
        float p[7];
        w.readPose(b, p);
        poses.insert(poses.end(), p, p + 7);
    }
    return poses;
}

void TestDeterminism()
{
    std::vector<float> a = Run(), b = Run();
    bool same = a.size() == b.size() && std::equal(a.begin(), a.end(), b.begin());
    Check(same, "two identical runs give identical poses");
}

// ---- dice: WorldSim's throw of world-dice.vera, replayed against Jolt

// fnv32, seededRandom (mulberry32), dieThrow and dieStartTurn as vera/VeraPhysics.ets has them, and kickAxis's throw
// from before them, for comparison. Keep them in step with that file.
uint32_t Fnv32(const std::string &s)
{
    uint32_t h = 0x811c9dc5u;
    for (char c : s) {
        h ^= static_cast<uint8_t>(c);
        h *= 16777619u;
    }
    return h;
}

struct Mulberry {
    uint32_t a;
    double operator()()
    {
        a += 0x6d2b79f5u;
        uint32_t t = a;
        t = (t ^ (t >> 15)) * (t | 1u);
        t ^= t + (t ^ (t >> 7)) * (t | 61u);
        return static_cast<double>(t ^ (t >> 14)) / 4294967296.0;
    }
};

constexpr double kPi = 3.14159265358979323846;
constexpr double kDieMinTurns = 4, kDieExtraTurns = 2, kDieTurnDeg = 20, kDieSpeedJitter = 0.25, kDieLiftJitter = 0.15;

void DieThrow(double vx, double vy, double vz, double spin, Mulberry &u, float *out6)
{
    double turns = std::max(std::fabs(spin), kDieMinTurns) + kDieExtraTurns * u();
    double phi = 2 * kPi * u();
    double w = turns * 2 * kPi;
    double turn = (2 * u() - 1) * kDieTurnDeg * kPi / 180;
    double scale = 1 + (2 * u() - 1) * kDieSpeedJitter;
    double lift = 1 + (2 * u() - 1) * kDieLiftJitter;
    double c = std::cos(turn), s = std::sin(turn);
    out6[0] = static_cast<float>((vx * c - vz * s) * scale);
    out6[1] = static_cast<float>(vy * lift);
    out6[2] = static_cast<float>((vx * s + vz * c) * scale);
    out6[3] = static_cast<float>(std::cos(phi) * w);
    out6[4] = 0;
    out6[5] = static_cast<float>(std::sin(phi) * w);
}

// dieStartTurn: one of the 24 turns of a cube onto itself, a face up and then a quarter turn about the upright.
void DieStartTurn(Mulberry &u, float *q)
{
    const double h = std::sqrt(0.5);
    const double faces[6][4] = {{0, 0, 0, 1}, {1, 0, 0, 0}, {0, 0, h, h}, {0, 0, -h, h}, {-h, 0, 0, h}, {h, 0, 0, h}};
    const double *b = faces[std::min(5, static_cast<int>(u() * 6))];
    double half = std::min(3, static_cast<int>(u() * 4)) * kPi / 4;
    double a[4] = {0, std::sin(half), 0, std::cos(half)};
    q[0] = static_cast<float>(a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1]);
    q[1] = static_cast<float>(a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0]);
    q[2] = static_cast<float>(a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3]);
    q[3] = static_cast<float>(a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2]);
}

void OldThrow(const std::string &id, int trigger, double vx, double vy, double vz, double spin, float *out6)
{
    uint32_t h = Fnv32(id + "#" + std::to_string(trigger));
    double a[3] = {((h & 0x3ff) / 1023.0) * 2 - 1, (((h >> 10) & 0x3ff) / 1023.0) * 2 - 1, (((h >> 20) & 0x3ff) / 1023.0) * 2 - 1};
    double d = std::sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    double w = spin * 2 * kPi;
    out6[0] = static_cast<float>(vx);
    out6[1] = static_cast<float>(vy);
    out6[2] = static_cast<float>(vz);
    for (int k = 0; k < 3; k++) {
        out6[3 + k] = static_cast<float>(a[k] / d * w);
    }
}

int TopFace(const float *p7)
{
    float qx = p7[3], qy = p7[4], qz = p7[5], qw = p7[6];
    float ax = 2 * (qx * qy + qz * qw), ay = 1 - 2 * (qx * qx + qz * qz), az = 2 * (qy * qz - qx * qw);
    float bx = std::fabs(ax), by = std::fabs(ay), bz = std::fabs(az);
    if (bx >= by && bx >= bz) {
        return ax > 0 ? 3 : 4;
    }
    if (by >= bz) {
        return ay > 0 ? 2 : 5;
    }
    return az > 0 ? 1 : 6;
}

// The table WorldSim builds for scene.table(1.2, 0.9): the top and four walls standing TABLE_GLASS_RATIO higher than drawn.
void Table(vphys::PhysWorld &w)
{
    const float parts[5][6] = {
        {0, -0.02f, 0, 1.245f, 0.04f, 0.945f},
        {0, 0.354f, -0.46125f, 1.245f, 0.708f, 0.0225f},
        {0, 0.354f, 0.46125f, 1.245f, 0.708f, 0.0225f},
        {-0.61125f, 0.354f, 0, 0.0225f, 0.708f, 0.9f},
        {0.61125f, 0.354f, 0, 0.0225f, 0.708f, 0.9f},
    };
    for (const auto &p : parts) {
        int i = w.addBox(p[3] / 2, p[4] / 2, p[5] / 2, vphys::kStatic);
        w.setPose(i, p[0], p[1], p[2], 0, 0, 0, 1);
        w.setMaterial(i, 0, 0.3f, 0.6f);
    }
    w.setGravity(-9.81f);
    w.setBound(-1, 0.6f + 0.0225f + 0.05f, 0.45f + 0.0225f + 0.05f);
}

struct DiceRun {
    std::vector<int> faces = std::vector<int>(7, 0);
    int repeats = 0;  // throws that showed the face the throw before showed
    int cocked = 0;   // throws after which d1 lay leaning (on the other die or a wall), its top face read all the same
};

// world-dice.vera thrown `throws` times, each from where the dice last lay; the faces of the white die (d1) counted. `fair`:
// WorldSim's throw of a die now (dieStartTurn, dieThrow, seeded as on the host, mixed with `salt`); else the throw before.
DiceRun ThrowDice(int throws, bool fair, uint32_t salt = 0)
{
    vphys::PhysWorld w;
    w.init(64, 0);
    Table(w);
    int d[2];
    const char *ids[2] = {"d1", "d2"};
    const float start[2][3] = {{-0.2f, 0.3f, 0.1f}, {0.2f, 0.3f, 0.1f}};
    for (int k = 0; k < 2; k++) {
        d[k] = w.addBox(0.08f, 0.08f, 0.08f, vphys::kDynamic);
        float q[4] = {0, 0, 0, 1};
        if (fair) {
            Mulberry u{Fnv32(std::string(ids[k]) + "#start") ^ salt};
            DieStartTurn(u, q);
        }
        w.setPose(d[k], start[k][0], start[k][1], start[k][2], q[0], q[1], q[2], q[3]);
        w.setMaterial(d[k], 1, 0.3f, 0.6f);
    }
    for (int i = 0; i < 600 && w.awakeDynamic() > 0; i++) {
        w.step(kDt, 1);
    }
    DiceRun run;
    int last = 0;
    for (int t = 1; t <= throws; t++) {
        double way = t % 2 == 1 ? -1 : 1;
        const double kick[2][4] = {{0.5 * way, 2.2, -0.4 * way, 2}, {0.4 * way, 2.4, 0.3 * way, 2.5}};
        for (int k = 0; k < 2; k++) {
            float v[6];
            if (fair) {
                Mulberry u{Fnv32(std::string(ids[k]) + "#" + std::to_string(t)) ^ salt};
                DieThrow(kick[k][0], kick[k][1], kick[k][2], kick[k][3], u, v);
            } else {
                OldThrow(ids[k], t, kick[k][0], kick[k][1], kick[k][2], kick[k][3], v);
            }
            w.setVelocity(d[k], v[0], v[1], v[2], v[3], v[4], v[5]);
        }
        int steps = 0;
        while (steps < 10 * 60 && (steps < 2 || w.awakeDynamic() > 0)) {
            w.step(kDt, 1);
            steps++;
        }
        float p[7];
        w.readPose(d[0], p);
        float up = std::max(std::fabs(2 * (p[3] * p[4] + p[5] * p[6])),
                            std::max(std::fabs(1 - 2 * (p[3] * p[3] + p[5] * p[5])), std::fabs(2 * (p[4] * p[5] - p[3] * p[6]))));
        int face = TopFace(p);
        run.cocked += up < 0.95f ? 1 : 0;
        run.faces[face]++;
        run.repeats += face == last ? 1 : 0;
        last = face;
    }
    return run;
}

// Spread of six counts: chi-square against even, and the smallest and largest.
double Chi2(const std::vector<int> &c, int n, int *lo, int *hi)
{
    double chi2 = 0, e = n / 6.0;
    *lo = n;
    *hi = 0;
    for (int f = 1; f <= 6; f++) {
        chi2 += (c[f] - e) * (c[f] - e) / e;
        *lo = std::min(*lo, c[f]);
        *hi = std::max(*hi, c[f]);
    }
    return chi2;
}

// Phone, phase 3: the white die showed 2, 4, 4, 1, 2 -- exactly the first five throws of the old replay below, the same
// every start, from face 2 up. 600 throws in a row and the first throw of 600 starts, each face expected 100 (sd 9). The
// same face twice in a row: 100 of 600 for a fair die; over 3000 throws Jolt gives 18.5% with either throw (a die that
// lands does not forget the face it was thrown from entirely), so the check is that it stays near that.
void TestDiceFair()
{
    const int n = 600;
    for (int fair = 0; fair < 2; fair++) {
        DiceRun r = ThrowDice(n, fair == 1);
        int lo = 0, hi = 0;
        double chi2 = Chi2(r.faces, n, &lo, &hi);
        std::printf("      %s throw, %d in a row, d1: 1:%d 2:%d 3:%d 4:%d 5:%d 6:%d  chi2 %.1f  same face twice %d  leaning %d\n",
                    fair ? "fair" : "old ", n, r.faces[1], r.faces[2], r.faces[3], r.faces[4], r.faces[5], r.faces[6], chi2,
                    r.repeats, r.cocked);
        if (fair) {
            Check(lo >= 75 && hi <= 125 && chi2 < 20.5, "600 throws in a row: every face 100 +- 25, chi-square < 20.5 (p 0.001)");
            Check(r.repeats < 140, "the same face twice in a row under 140 times of 600 (fair: 100, Jolt over 3000: 111)");
        }
    }
    std::vector<int> first(7, 0);
    for (int k = 0; k < n; k++) {
        DiceRun r = ThrowDice(1, true, Fnv32("start" + std::to_string(k)));
        for (int f = 1; f <= 6; f++) {
            first[f] += r.faces[f];
        }
    }
    int lo = 0, hi = 0;
    double chi2 = Chi2(first, n, &lo, &hi);
    std::printf("      fair throw, the first of %d starts, d1: 1:%d 2:%d 3:%d 4:%d 5:%d 6:%d  chi2 %.1f\n", n, first[1], first[2],
                first[3], first[4], first[5], first[6], chi2);
    Check(lo >= 75 && hi <= 125 && chi2 < 20.5, "the first throw of 600 starts: every face 100 +- 25, chi-square < 20.5");
}

// The NAPI glue sizes every write into a Float32Array by FloatCapacity. OpenHarmony reports a typed
// array's length in bytes; sized by that, drainContacts wrote 4x past the ArkTS buffer and the app
// died in ArkUI layout during a wall's collapse.
void TestFloatCapacity()
{
    // ArkTS's contacts array: new Float32Array(256 * 3), 3072 bytes, reported as 3072 on OpenHarmony.
    Check(vphys::FloatCapacity(768, 3072, 3072, 0) == 768, "capacity: OpenHarmony's byte length is not taken for floats");
    Check(vphys::FloatCapacity(768, 768, 3072, 0) == 768, "capacity: Node's element length gives the same");
    Check(vphys::FloatCapacity(768, 3072, 3072, 0) / 3 == 256, "capacity: 256 contact triples, not 1024");
    Check(vphys::FloatCapacity(16384, 65536, 65536, 0) / 8 == 2048, "capacity: 2048 poses, not 8192");
    Check(vphys::FloatCapacity(10, 40, 64, 32) == 8, "capacity: a view near the end of its buffer stops at the end");
    Check(vphys::FloatCapacity(10, 40, 16, 32) == 0, "capacity: an offset past the buffer gives nothing");
    Check(vphys::FloatCapacity(-1, 40, 64, 0) == 0 && vphys::FloatCapacity(NAN, 40, 64, 0) == 0,
          "capacity: no length, no writes");
    Check(vphys::FloatCapacity(1e30, 12, 64, 0) == 12, "capacity: never more than reported");
}

// A wall knocked down begins far more contacts in one step than the ArkTS buffer holds: a drain sized
// for 256 triples writes 256 and not one float more (the floats past it stay untouched).
void TestDrainBounded()
{
    vphys::PhysWorld w;
    w.init(256, 0);
    Floor(w);
    std::vector<int> cubes;
    const float side = 0.1f;
    for (int row = 0; row < 10; row++) {
        for (int col = 0; col < 10; col++) {
            int i = w.addBox(side * 0.49f, side * 0.49f, side * 0.49f, vphys::kDynamic);
            w.setPose(i, (col - 4.5f) * side, side / 2 + row * side, 0, 0, 0, 0, 1);
            cubes.push_back(i);
        }
    }
    int ball = w.addSphere(0.1f, vphys::kDynamic);
    w.setPose(ball, 0, 0.3f, 1.0f, 0, 0, 0, 1);
    w.setMaterial(ball, 3, 0.3f, 0.5f);
    w.setVelocity(ball, 0, 0, -8, 0, 0, 0);
    const int cap = 256;
    const int guard = 64;
    std::vector<float> out(static_cast<size_t>(cap) * kRec + guard, -12345.0f);
    int most = 0;
    bool intact = true;
    uint32_t droppedBefore = w.droppedContacts();
    for (int s = 0; s < 120; s++) {
        w.step(kDt, 1);
        int n = w.drainContacts(out.data(), cap);
        most = std::max(most, n);
        for (int k = cap * kRec; k < cap * kRec + guard; k++) {
            if (out[static_cast<size_t>(k)] != -12345.0f) {
                intact = false;
            }
        }
    }
    std::printf("      wall: most contacts in one drain %d (cap %d), dropped %u\n", most, cap,
                w.droppedContacts() - droppedBefore);
    Check(most <= cap && intact, "drain: never writes past its cap");
}

// The 8 s sleep cap belongs to each body. Long after the last kick, a body added in the air still
// falls, and one that jitters for ever (kept awake here by a kinematic body pushing it) is capped.
void TestSleepCap()
{
    vphys::PhysWorld w;
    w.init(64, 0);
    Floor(w);
    int a = w.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
    w.setPose(a, 0, 0.05f, 0, 0, 0, 0, 1);
    w.setVelocity(a, 0, 0, 0, 0, 0, 0);
    for (int i = 0; i < 60 * 10; i++) {
        w.step(kDt, 1);
    }
    int b = w.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
    w.setPose(b, 1, 1, 0, 0, 0, 0, 1);
    for (int i = 0; i < 60; i++) {
        w.step(kDt, 1);
    }
    float p[7];
    w.readPose(b, p);
    std::printf("      body added 10 s after the last kick: y = %.4f after 1 s\n", p[1]);
    Check(p[1] < 0.1f, "sleep cap: a body added long after the last kick still falls");
    // A body held awake by a sliding kinematic paddle: it is put to sleep once 8 s in a row pass.
    vphys::PhysWorld k;
    k.init(64, 0);
    Floor(k);
    int paddle = k.addBox(0.3f, 0.05f, 0.3f, vphys::kKinematic);
    k.setPose(paddle, 0, 0.05f, 0, 0, 0, 0, 1);
    int c = k.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
    k.setPose(c, 0, 0.16f, 0, 0, 0, 0, 1);
    int awakeSteps = 0;
    for (int i = 0; i < 60 * 12; i++) {
        float x = 0.05f * std::sin(i * kDt * 20.0f);
        k.moveKinematic(paddle, x, 0.05f, 0, 0, 0, 0, 1, kDt);
        k.step(kDt, 1);
        awakeSteps += k.awakeDynamic();
    }
    std::printf("      on a shaking paddle: awake %d of %d steps\n", awakeSteps, 60 * 12);
    Check(awakeSteps > 60 * 8 - 10, "sleep cap: a body pushed all along stays awake up to its cap");
    // In a world without gravity a thrown body drifts on (slowed only by its damping, 9 m in 12 s): free flight is not
    // counted by the cap.
    vphys::PhysWorld g;
    g.init(64, 0);
    g.setGravity(0);
    g.setBound(-50, 50, 50);
    int d = g.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
    g.setPose(d, 0, 0, 0, 0, 0, 0, 1);
    g.setVelocity(d, 1, 0, 0, 0, 0, 0);
    for (int i = 0; i < 60 * 12; i++) {
        g.step(kDt, 1);
    }
    g.readPose(d, p);
    std::printf("      drifting without gravity for 12 s: x = %.2f, awake %d\n", p[0], g.awakeDynamic());
    Check(p[0] > 8.5f && g.awakeDynamic() == 1, "sleep cap: a body in free flight is not stopped in mid-air");
}

// Bodies of any shape: records of convex parts (PhysWorld::addParts), one rigid body. A prism is an outline's corners at
// its top and bottom; a part record is [type, p, q, a, b, c, n].
struct Parts {
    std::vector<float> records;
    std::vector<float> points;
    void Part(int type, float px, float py, float pz, float a, float b, float c, int n = 0,
              float qx = 0, float qy = 0, float qz = 0, float qw = 1)
    {
        records.insert(records.end(), {static_cast<float>(type), px, py, pz, qx, qy, qz, qw, a, b, c, static_cast<float>(n)});
    }
    void Hull(const std::vector<float> &v, float px = 0, float py = 0, float pz = 0)
    {
        Part(3, px, py, pz, 0, 0, 0, static_cast<int>(v.size() / 3));
        points.insert(points.end(), v.begin(), v.end());
    }
    int Add(vphys::PhysWorld &w, int kind = vphys::kDynamic)
    {
        return w.addParts(records.data(), static_cast<int>(records.size() / 12), points.empty() ? nullptr : points.data(),
                          points.size(), kind);
    }
};

std::vector<float> Prism(const std::vector<float> &xz, float h)
{
    std::vector<float> v;
    for (size_t i = 0; i + 1 < xz.size(); i += 2) {
        v.insert(v.end(), {xz[i], h / 2, xz[i + 1], xz[i], -h / 2, xz[i + 1]});
    }
    return v;
}

float Settle(vphys::PhysWorld &w, int b, float *p)
{
    int steps = 0;
    while (steps < 900 && (steps < 10 || w.awakeDynamic() > 0)) {
        w.step(kDt, 1);
        steps++;
    }
    w.readPose(b, p);
    return static_cast<float>(steps);
}

// Where a point fixed in the body (bx, by, bz from its origin) is in the world, for pose p.
void BodyPoint(const float *p, float bx, float by, float bz, float *out)
{
    JPH::Vec3 v = JPH::Quat(p[3], p[4], p[5], p[6]) * JPH::Vec3(bx, by, bz);
    out[0] = p[0] + v.GetX(); out[1] = p[1] + v.GetY(); out[2] = p[2] + v.GetZ();
}

void TestParts()
{
    {
        // A flat triangle 2 cm thick dropped flat lands on a face: its centre at half its thickness, still level.
        vphys::PhysWorld w;
        w.init(64, 0);
        Floor(w);
        Parts t;
        t.Hull(Prism({0, -0.1f, 0.1f, 0.07f, -0.1f, 0.07f}, 0.02f));
        int b = t.Add(w);
        Check(b >= 0, "parts: a triangle prism is made");
        w.setPose(b, 0, 0.3f, 0, 0, 0, 0, 1);
        float p[7];
        float steps = Settle(w, b, p);
        std::printf("      triangle: y = %.4f after %.0f steps\n", p[1], steps);
        Check(std::fabs(p[1] - 0.01f) < 0.002f && w.awakeDynamic() == 0, "parts: a dropped triangle lies flat on the floor");
    }
    {
        // A sheet (scene.shape with h 0: 2 mm on a 20 cm triangle) dropped from 30 cm lies flat, not through the floor.
        vphys::PhysWorld w;
        w.init(64, 0);
        Floor(w);
        Parts t;
        t.Hull(Prism({0, -0.1f, 0.1f, 0.07f, -0.1f, 0.07f}, 0.002f));
        int b = t.Add(w);
        Check(b >= 0, "parts: a sheet 2 mm thick is made");
        w.setPose(b, 0, 0.3f, 0, 0, 0, 0, 1);
        w.setVelocity(b, 0.2f, 0, 0, 1, 0, 2);
        float p[7];
        Settle(w, b, p);
        std::printf("      sheet: y = %.4f\n", p[1]);
        Check(p[1] > 0 && p[1] < 0.004f && w.awakeDynamic() == 0, "parts: a dropped sheet lies flat on the floor");
    }
    {
        // The thinnest sheet scene.shape makes (1 mm, an outline under 10 cm): pieces of a 5 cm star, as thick as Jolt's
        // default hull tolerance. It is made (the tolerance lets points lie outside the hull, it does not flatten it),
        // and it lies on the floor.
        vphys::PhysWorld w;
        w.init(64, 0);
        Floor(w);
        Parts t;
        t.Hull(Prism({0, 0, 0.025f, 0.004f, 0.025f, -0.004f}, 0.001f));
        t.Hull(Prism({0, 0, -0.012f, 0.02f, -0.012f, -0.02f}, 0.001f));
        int b = t.Add(w);
        Check(b >= 0, "parts: a sheet 1 mm thick on a 5 cm outline is made");
        w.setPose(b, 0, 0.1f, 0, 0, 0, 0, 1);
        float p[7];
        Settle(w, b, p);
        std::printf("      1 mm sheet: y = %.5f\n", p[1]);
        Check(p[1] > 0 && p[1] < 0.003f, "parts: and it lies on the floor");
    }
    {
        // A thrown triangle comes to rest on one of its faces, never inside the floor.
        vphys::PhysWorld w;
        w.init(64, 0);
        Floor(w);
        Parts t;
        t.Hull(Prism({0, -0.1f, 0.1f, 0.07f, -0.1f, 0.07f}, 0.04f));
        int b = t.Add(w);
        w.setPose(b, 0, 0.3f, 0, 0, 0, 0, 1);
        w.setVelocity(b, 0.5f, 2, 0.2f, 6, 3, 9);
        float p[7];
        Settle(w, b, p);
        std::printf("      thrown triangle at rest: y = %.4f\n", p[1]);
        Check(p[1] > 0.015f && p[1] < 0.1f && w.awakeDynamic() == 0, "parts: a thrown triangle comes to rest above the floor");
    }
    {
        // An L of two hulls stands on the floor as one body: neither piece sinks or comes apart.
        vphys::PhysWorld w;
        w.init(64, 0);
        Floor(w);
        Parts l;
        l.Hull(Prism({0, 0, 0.3f, 0, 0.3f, 0.1f, 0, 0.1f}, 0.05f));
        l.Hull(Prism({0, 0.1f, 0.1f, 0.1f, 0.1f, 0.3f, 0, 0.3f}, 0.05f));
        int b = l.Add(w);
        Check(b >= 0, "parts: an L of two pieces is made");
        w.setPose(b, 0, 0.2f, 0, 0, 0, 0, 1);
        float p[7];
        Settle(w, b, p);
        std::printf("      L: y = %.4f\n", p[1]);
        Check(std::fabs(p[1] - 0.025f) < 0.003f && w.awakeDynamic() == 0, "parts: an L lies flat at half its thickness");
    }
    {
        // A pyramid set down on its base goes to sleep there.
        vphys::PhysWorld w;
        w.init(64, 0);
        Floor(w);
        Parts py;
        py.Hull({-0.1f, 0, -0.1f, 0.1f, 0, -0.1f, 0.1f, 0, 0.1f, -0.1f, 0, 0.1f, 0, 0.15f, 0});
        int b = py.Add(w);
        w.setPose(b, 0, 0.05f, 0, 0, 0, 0, 1);
        float p[7];
        Settle(w, b, p);
        std::printf("      pyramid: y = %.4f, |q.w| %.4f\n", p[1], std::fabs(p[6]));
        Check(std::fabs(p[1]) < 0.003f && std::fabs(p[6]) > 0.999f && w.awakeDynamic() == 0, "parts: a pyramid rests on its base");
    }
    {
        // A snowman of three balls, set down on the bottom one, stands: its head stays over its middle.
        vphys::PhysWorld w;
        w.init(64, 0);
        Floor(w);
        Parts s;
        s.Part(1, 0, 0.15f, 0, 0.15f, 0, 0);
        s.Part(1, 0, 0.36f, 0, 0.1f, 0, 0);
        s.Part(1, 0, 0.51f, 0, 0.06f, 0, 0);
        int b = s.Add(w);
        Check(b >= 0, "parts: a snowman of three balls is made");
        w.setPose(b, 0, 0.001f, 0, 0, 0, 0, 1);
        float p[7];
        Settle(w, b, p);
        float head[3];
        BodyPoint(p, 0, 0.51f, 0, head);
        std::printf("      snowman: head at %.3f, %.3f, %.3f\n", head[0], head[1], head[2]);
        Check(std::fabs(head[1] - 0.51f) < 0.01f && std::hypot(head[0], head[2]) < 0.01f, "parts: a snowman stands");
    }
    {
        // A dumbbell (two balls on a bar along x) thrown along the floor rolls as one body: its balls stay a bar apart.
        vphys::PhysWorld w;
        w.init(64, 0);
        Floor(w);
        Parts d;
        float h = std::sqrt(0.5f);
        d.Part(2, 0, 0, 0, 0.02f, 0.15f, 0, 0, 0, 0, h, h);  // the bar, a cylinder turned onto its side
        d.Part(1, -0.15f, 0, 0, 0.05f, 0, 0);
        d.Part(1, 0.15f, 0, 0, 0.05f, 0, 0);
        int b = d.Add(w);
        Check(b >= 0, "parts: a dumbbell is made");
        w.setPose(b, 0, 0.06f, 0, 0, 0, 0, 1);
        w.setVelocity(b, 0, 0, 1.0f, 0, 0, 0);
        float p[7];
        for (int i = 0; i < 60; i++) {
            w.step(kDt, 1);
        }
        w.readPose(b, p);
        float l[3], r[3];
        BodyPoint(p, -0.15f, 0, 0, l);
        BodyPoint(p, 0.15f, 0, 0, r);
        float apart = std::sqrt((l[0] - r[0]) * (l[0] - r[0]) + (l[1] - r[1]) * (l[1] - r[1]) + (l[2] - r[2]) * (l[2] - r[2]));
        std::printf("      dumbbell after 1 s: z = %.3f, balls at y %.3f / %.3f\n", p[2], l[1], r[1]);
        Check(p[2] > 0.2f && std::fabs(l[1] - 0.05f) < 0.01f && std::fabs(r[1] - 0.05f) < 0.01f && std::fabs(apart - 0.3f) < 1e-3f,
              "parts: a dumbbell rolls on its balls as one body");
    }
    {
        // A hammer (a long light handle, a heavy head at one end) has its centre of mass near the head.
        vphys::PhysWorld w;
        w.init(64, 0);
        Floor(w);
        Parts m;
        m.Part(0, 0, 0, 0, 0.015f, 0.15f, 0.015f);       // handle along y, 30 cm
        m.Part(0, 0, 0.17f, 0, 0.06f, 0.025f, 0.025f);   // head across the top
        int b = m.Add(w);
        w.setPose(b, 0, 0.5f, 0, 0, 0, 0, 1);
        w.setVelocity(b, 0.3f, 1, 0, 4, 2, 6);
        float p[7];
        Settle(w, b, p);
        float top[3], bottom[3];
        BodyPoint(p, 0, 0.17f, 0, top);
        BodyPoint(p, 0, -0.15f, 0, bottom);
        std::printf("      hammer at rest: head y %.3f, handle end y %.3f\n", top[1], bottom[1]);
        Check(w.awakeDynamic() == 0 && top[1] > 0 && bottom[1] > -0.01f, "parts: a thrown hammer comes to rest, whole, on the floor");
    }
    {
        // Refused: points in one plane, three points, a size past the points, an unknown type, a box of no size.
        vphys::PhysWorld w;
        w.init(64, 0);
        Parts flat;
        flat.Hull({0, 0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 1});
        Check(flat.Add(w) < 0, "parts: points in one plane are refused");
        Parts three;
        three.Hull({0, 0, 0, 1, 0, 0, 0, 1, 0});
        Check(three.Add(w) < 0, "parts: three points are refused");
        Parts past;
        past.Part(3, 0, 0, 0, 0, 0, 0, 9);
        past.points = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
        Check(past.Add(w) < 0, "parts: a hull past the points is refused");
        Parts odd;
        odd.Part(7, 0, 0, 0, 1, 1, 1);
        Check(odd.Add(w) < 0, "parts: an unknown type is refused");
        Parts none;
        none.Part(0, 0, 0, 0, 0.1f, 0, 0.1f);
        Check(none.Add(w) < 0, "parts: a box of no height is refused");
        Parts many;
        for (int k = 0; k < 33; k++) {
            many.Part(1, k * 0.1f, 0, 0, 0.04f, 0, 0);
        }
        Check(many.Add(w) < 0, "parts: more than 32 parts are refused");
    }
}

// Rolling and spinning resistance: Jolt has neither, so round bodies used to move until the 8 s sleep cap stopped them
// in mid-roll. A ball rolled at 1 m/s comes to rest by itself a metre or two on, and a snowman (three balls and a hat)
// thrown spinning stops spinning on its foot and rolling on its side well before the cap.
void TestRolling()
{
    vphys::PhysWorld w;
    w.init(64, 0);
    Floor(w);
    int ball = w.addSphere(0.1f, vphys::kDynamic);
    w.setPose(ball, 0, 0.1f, 0, 0, 0, 0, 1);
    w.setVelocity(ball, 1, 0, 0, 0, 0, -10);
    float p[7];
    float steps = Settle(w, ball, p);
    std::printf("      ball rolled at 1 m/s: %.2f m, asleep after %.2f s\n", p[0], steps * kDt);
    Check(p[0] > 0.8f && p[0] < 2.5f && steps * kDt < 5.0f, "rolling: a rolled ball slows and stops by itself");
    const float axes[4][3] = {{1, 1, 0}, {0.3f, 1, 0.7f}, {1, 1, 1}, {-0.2f, 0.9f, -1}};
    float longest = 0;
    for (const float *a : axes) {
        vphys::PhysWorld s;
        s.init(64, 0);
        Floor(s);
        Parts man;
        man.Part(1, 0, -0.35f, 0, 0.3f, 0, 0);
        man.Part(1, 0, 0.07f, 0, 0.22f, 0, 0);
        man.Part(1, 0, 0.41f, 0, 0.15f, 0, 0);
        man.Part(2, 0, 0.62f, 0, 0.12f, 0.08f, 0);
        int b = man.Add(s);
        s.setPose(b, 0, 0.67f, 0, 0, 0, 0, 1);
        float n = std::sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]), om = 4 * static_cast<float>(M_PI) / n;
        s.setVelocity(b, 0.5f, 2.4f, 0.3f, a[0] * om, a[1] * om, a[2] * om);
        int k = 0;
        while (k < 60 * 9 && (k < 5 || s.awakeDynamic() > 0)) {
            s.step(kDt, 1);
            k++;
        }
        longest = std::max(longest, k * kDt);
    }
    std::printf("      snowman thrown spinning: the longest of 4 throws asleep after %.2f s\n", longest);
    Check(longest < 7.5f, "rolling: a thrown snowman comes to rest before the sleep cap");
}

// A character (kind 3, scene.player): driven along the ground it goes the way and as far as it is driven, stays upright
// against a wall, turns about y as asked, still falls and jumps, never keeps a throw from settling, sleeps once let go,
// and the world bound puts it back. A group character (a horse of parts) behaves the same.
bool Upright(const float *p) { return std::fabs(p[3]) < 1e-3f && std::fabs(p[5]) < 1e-3f; }

void Drive(vphys::PhysWorld &w, int b, float vx, float vz, float wy, int steps)
{
    for (int k = 0; k < steps; k++) {
        w.drive(b, vx, vz, wy);
        w.step(kDt, 1);
    }
}

void TestCharacter()
{
    {
        vphys::PhysWorld w;
        w.init(64, 0);
        int f = w.addBox(100, 0.5f, 100, vphys::kStatic);
        w.setPose(f, 0, -0.5f, 0, 0, 0, 0, 1);
        w.setBound(-5, 99, 99);
        int c = w.addBox(0.4f, 0.4f, 0.25f, vphys::kCharacter);
        w.setPose(c, 0, 0.4f, 0, 0, 0, 0, 1);
        w.setMaterial(c, 1, 0.3f, 0.6f);
        Check(c >= 0, "character: made");
        Check(w.awakeDynamic() == 0, "character: not counted among the dynamic bodies a throw waits for");
        float p[7];
        Drive(w, c, 2, 0, 0, 120);
        w.readPose(c, p);
        std::printf("      driven 2 m/s for 2 s: x = %.3f y = %.4f\n", p[0], p[1]);
        Check(std::fabs(p[0] - 4.0f) < 0.4f, "character: goes as far as it is driven (4 m +-10%)");
        float v[3];
        Check(w.readVelocity(c, v) && std::fabs(v[0] - 2) < 0.05f && std::fabs(v[2]) < 0.05f, "character: readVelocity has its going");
        Check(!w.readVelocity(999, v), "readVelocity: no such body");
        Check(std::fabs(p[1] - 0.4f) < 0.02f && Upright(p), "character: stays on the floor, upright");
        // Turning: 90 degrees a second for a second.
        Drive(w, c, 0, 0, static_cast<float>(M_PI / 2), 60);
        w.readPose(c, p);
        float yaw = 2 * std::atan2(p[4], p[6]) * 180 / static_cast<float>(M_PI);
        std::printf("      turned: yaw = %.1f degrees\n", yaw);
        Check(std::fabs(yaw - 90) < 6 && Upright(p), "character: turns about y as it is told");
        // Let go: it stops where it is and goes to sleep.
        w.drive(c, 0, 0, 0);
        float x0 = p[0];
        float moved[8 * 4];
        int still = 0;
        for (int k = 0; k < 120; k++) {
            w.step(kDt, 1);
            still = w.readAwake(moved, 4) == 0 ? still + 1 : 0;
        }
        w.readPose(c, p);
        Check(still > 10, "character: let go, it goes to sleep");
        Check(std::fabs(p[0] - x0) < 0.02f, "character: let go, it stays where it is");
        // A wall: driven into a static box it stops at it and stays upright.
        int wall = w.addBox(0.2f, 1, 3, vphys::kStatic);
        w.setPose(wall, p[0] + 2, 1, p[2], 0, 0, 0, 1);
        Drive(w, c, 3, 0, 0, 120);
        w.readPose(c, p);
        std::printf("      against a wall: x = %.3f (wall face at %.3f), q = %.4f %.4f %.4f %.4f\n", p[0], x0 + 2 - 0.2f, p[3], p[4], p[5], p[6]);
        Check(p[0] < x0 + 2 - 0.2f - 0.2f && Upright(p), "character: stopped by a wall, upright");
        // A jump: an upward velocity takes it up, and it lands.
        w.setVelocity(c, 0, 4, 0, 0, 0, 0);
        float top = 0;
        for (int k = 0; k < 90; k++) {
            w.drive(c, 0, 0, 0);
            w.step(kDt, 1);
            w.readPose(c, p);
            top = std::max(top, p[1]);
        }
        std::printf("      jump: top y = %.3f, landed y = %.4f\n", top, p[1]);
        Check(top > 1.0f && std::fabs(p[1] - 0.4f) < 0.02f, "character: driving keeps its fall: it jumps and lands");
        // Falling off a height while driven: it keeps falling.
        w.setPose(c, -10, 3, 0, 0, 0, 0, 1);
        Drive(w, c, 1, 0, 0, 60);
        w.readPose(c, p);
        Check(p[1] < 0.6f, "character: driven in the air it still falls");
        // The bound puts it back where it was last placed.
        w.setPose(c, 5, 0.4f, 5, 0, 0, 0, 1);
        float farthest = 0;
        bool back = false;
        for (int k = 0; k < 150; k++) {
            w.drive(c, 0, 60, 0);
            w.step(kDt, 1);
            w.readPose(c, p);
            farthest = std::max(farthest, std::fabs(p[2]));
            back = back || (k > 0 && std::fabs(p[2] - 5) < 0.01f);
        }
        std::printf("      driven off the world: farthest z %.1f\n", farthest);
        Check(back && farthest < 99 + 1.1f, "character: the world bound brings it back");
        // A thrown die settles while the character walks about.
        int die = w.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
        w.setPose(die, 3, 0.5f, 3, 0, 0, 0, 1);
        w.setVelocity(die, 1, 2, 0, 5, 1, 2);
        int k = 0;
        bool settled = false;
        for (; k < 600 && !settled; k++) {
            w.drive(c, 1, 0, 0.5f);
            w.step(kDt, 1);
            settled = k > 10 && w.awakeDynamic() == 0;
        }
        Check(settled, "character: a throw settles while it walks");
    }
    {
        // A horse of parts as a character: it walks upright.
        vphys::PhysWorld w;
        w.init(64, 0);
        Floor(w);
        Parts h;
        h.Part(0, 0, 0.8f, 0, 0.6f, 0.2f, 0.2f);
        for (float x : {-0.45f, 0.45f}) {
            for (float z : {-0.15f, 0.15f}) { h.Part(0, x, 0.3f, z, 0.05f, 0.3f, 0.05f); }
        }
        h.Part(0, 0.75f, 1.1f, 0, 0.15f, 0.25f, 0.1f);
        int c = h.Add(w, vphys::kCharacter);
        Check(c >= 0, "character: a group of parts can be one");
        float p[7];
        w.readPose(c, p);
        float y0 = p[1];
        w.setPose(c, 0, y0 + 0.01f, 0, 0, 0, 0, 1);
        Drive(w, c, 1.5f, 0.5f, 0.3f, 180);
        w.readPose(c, p);
        std::printf("      horse: at %.2f %.2f, y %.3f, q %.4f %.4f %.4f %.4f\n", p[0], p[2], p[1], p[3], p[4], p[5], p[6]);
        Check(p[0] > 3.5f && Upright(p), "character: a group walks upright on its four legs");
    }
    {
        // Two runs are the same.
        float a[7], b[7];
        for (float *out : {a, b}) {
            vphys::PhysWorld w;
            w.init(64, 0);
            Floor(w);
            int c = w.addBox(0.3f, 0.3f, 0.3f, vphys::kCharacter);
            w.setPose(c, 0, 0.3f, 0, 0, 0, 0, 1);
            int box = w.addBox(0.2f, 0.2f, 0.2f, vphys::kDynamic);
            w.setPose(box, 1.5f, 0.2f, 0.05f, 0, 0, 0, 1);
            Drive(w, c, 2, 0, 0.2f, 120);
            w.readPose(box, out);
        }
        Check(std::equal(a, a + 7, b), "character: deterministic, and it pushes a loose box");
        Check(a[0] > 1.6f, "character: the box it walked into moved");
    }
}

// ---- shots, blasts, watched bodies

// Run before the rest: whether Jolt calls OnContactAdded for a hit its continuous collision (LinearCast) finds, and
// whether a 30 m/s projectile stops at a wall 2 cm thick. A discrete body of the same size is printed for comparison.
void TestLinearCastContact()
{
    for (int kind : {static_cast<int>(vphys::kProjectile), static_cast<int>(vphys::kDynamic)}) {
        vphys::PhysWorld w;
        w.init(64, 0);
        int wall = w.addBox(0.01f, 1, 1, vphys::kStatic);  // its face towards the shot at x = 1.99
        w.setPose(wall, 2, 1, 0, 0, 0, 0, 1);
        int p = w.addSphere(0.03f, kind);
        w.setPose(p, 0, 1, 0, 0, 0, 0, 1);
        w.setVelocity(p, 30, 0, 0, 0, 0, 0);
        float buf[kRec * 64];
        int records = 0, first = -1;
        float speed = 0, at[3] = {0, 0, 0}, most = -1e9f, pose[7];
        for (int s = 0; s < 60; s++) {
            w.step(kDt, 1);
            int n = w.drainContacts(buf, 64);
            for (int k = 0; k < n; k++) {
                const float *r = buf + k * kRec;
                if (Pair(r, p, wall)) {
                    records++;
                    if (first < 0) {
                        first = s;
                        speed = r[2];
                        std::copy(r + 3, r + 6, at);
                    }
                }
            }
            w.readPose(p, pose);
            most = std::max(most, pose[0]);
        }
        std::printf("      %s 3 cm sphere at 30 m/s into a 2 cm wall: %d contact begin(s), first at step %d, %.1f m/s at "
                    "(%.3f, %.3f, %.3f); furthest x %.3f\n", kind == vphys::kProjectile ? "LinearCast" : "discrete",
                    records, first, speed, at[0], at[1], at[2], most);
        if (kind == vphys::kProjectile) {
            Check(records >= 1, "LinearCast: Jolt reports OnContactAdded for a 30 m/s projectile hitting a 2 cm wall");
            Check(records == 1, "LinearCast: the hit begins once (the CCD contact is cached, not re-added next step)");
            Check(speed > 25 && std::fabs(at[0] - 1.99f) < 0.02f, "LinearCast: at the shot's speed, on the wall's face");
            Check(most < 1.99f, "LinearCast: the projectile does not pass through the wall");
        }
    }
}

void TestProjectile()
{
    {
        // Out of the bound: stopped where it left, asleep, not sent home, reported once; not waited for in flight.
        vphys::PhysWorld w;
        w.init(64, 0);
        w.setBound(-5, 3, 3);
        int p = w.addSphere(0.03f, vphys::kProjectile);
        w.setPose(p, 0, 1, 0, 0, 0, 0, 1);
        w.setVelocity(p, 30, 0, 0, 0, 0, 0);
        Check(w.watched(p), "projectile: watched from the start");
        bool counted = false, stopped = false;
        int stopStep = -1, listedAfter = 0;
        float stopPose[7] = {0}, pose[7];
        std::vector<float> awake(8 * 64);
        for (int s = 0; s < 120; s++) {
            w.step(kDt, 1);
            counted = counted || w.awakeDynamic() != 0;
            int n = w.readAwake(awake.data(), 64);
            bool listed = false;
            for (int k = 0; k < n; k++) { listed = listed || awake[k * 8] == static_cast<float>(p); }
            w.readPose(p, pose);
            if (!stopped && pose[0] > 3) {
                stopped = true;
                stopStep = s;
                std::copy(pose, pose + 7, stopPose);
                Check(listed, "projectile: its stop is reported by readAwake");
            } else if (stopped) {
                listedAfter += listed ? 1 : 0;
            }
        }
        float v[6];
        w.readVelocity(p, v, 6);
        std::printf("      projectile left the bound at step %d, x = %.3f y = %.5f; now x = %.3f, reported %d times after\n",
                    stopStep, stopPose[0], stopPose[1], pose[0], listedAfter);
        Check(stopped && std::fabs(stopPose[1] - 1) < 1e-4f, "projectile: flies straight without gravity until it leaves");
        Check(std::equal(pose, pose + 7, stopPose) && pose[0] > 3, "projectile: stays where it left the bound, not at home");
        Check(v[0] == 0 && v[1] == 0 && v[2] == 0 && v[3] == 0 && v[4] == 0 && v[5] == 0, "projectile: stopped dead");
        Check(listedAfter == 0, "projectile: asleep after its stop (reported once)");
        Check(!counted, "projectile: never counted by awakeDynamic");
        // Its index reused by an ordinary body: not watched, not a projectile.
        w.remove(p);
        int q = w.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
        Check(q == p && !w.watched(q) && w.awakeDynamic() == 1, "projectile: a reused index inherits nothing");
        w.watch(q, 1);
        Check(w.watched(q), "watch: any body can be watched");
        w.reset();
        int r = w.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
        Check(!w.watched(r), "watch: reset forgets it");
    }
    {
        // No gravity until it touches something, then it falls.
        vphys::PhysWorld w;
        w.init(64, 0);
        Floor(w);
        int block = w.addBox(0.2f, 0.5f, 0.5f, vphys::kStatic);
        w.setPose(block, 2, 0.5f, 0, 0, 0, 0, 1);
        int p = w.addSphere(0.03f, vphys::kProjectile);
        w.setPose(p, 0, 0.5f, 0, 0, 0, 0, 1);
        w.setVelocity(p, 5, 0, 0, 0, 0, 0);
        float pose[7], before = 0;
        bool hit = false;
        float buf[kRec * 64];
        for (int s = 0; s < 150; s++) {
            w.step(kDt, 1);
            int n = w.drainContacts(buf, 64);
            for (int k = 0; k < n; k++) { hit = hit || Pair(buf + k * kRec, p, block); }
            if (s == 15) {
                w.readPose(p, pose);
                before = pose[1];
            }
        }
        w.readPose(p, pose);
        std::printf("      projectile without arc: y = %.4f in flight, %.4f 2 s later\n", before, pose[1]);
        Check(std::fabs(before - 0.5f) < 1e-4f, "projectile: no gravity before it touches anything");
        Check(hit && pose[1] < 0.1f, "projectile: hits the block, then falls to the floor");
    }
    {
        vphys::PhysWorld w;
        w.init(64, 0);
        int p = w.addSphere(0.03f, vphys::kProjectileArc);
        w.setPose(p, 0, 10, 0, 0, 0, 0, 1);
        w.setVelocity(p, 5, 0, 0, 0, 0, 0);
        for (int s = 0; s < 30; s++) {
            w.step(kDt, 1);
        }
        float v[3];
        w.readVelocity(p, v);
        std::printf("      projectile with arc: vy = %.2f after 0.5 s\n", v[1]);
        Check(v[1] < -4 && w.watched(p), "projectile with arc: falls from the start, watched");
    }
}

// Contact records carry the world contact point: a box dropped on the floor touches it at y = 0, under the box.
void TestContactPoint()
{
    vphys::PhysWorld w;
    w.init(64, 0);
    int f = Floor(w);
    int b = w.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
    w.setPose(b, 0.3f, 0.5f, -0.2f, 0, 0, 0, 1);
    std::vector<float> buf(kRec * 64 + 8, -12345.0f);
    bool found = false;
    float at[3] = {0, 0, 0};
    for (int s = 0; s < 90 && !found; s++) {
        w.step(kDt, 1);
        int n = w.drainContacts(buf.data(), 64);
        for (int k = 0; k < n && !found; k++) {
            if (Pair(buf.data() + k * kRec, b, f)) {
                found = true;
                std::copy(buf.data() + k * kRec + 3, buf.data() + k * kRec + 6, at);
            }
        }
    }
    std::printf("      box on the floor: contact at (%.4f, %.4f, %.4f)\n", at[0], at[1], at[2]);
    Check(found && std::fabs(at[1]) < 0.01f, "contact point: on the floor plane");
    Check(std::fabs(at[0] - 0.3f) < 0.06f && std::fabs(at[2] + 0.2f) < 0.06f, "contact point: under the box");
}

// A wall collapsing fills the contact buffer between drains; a watched body's contact still finds room in the reserve,
// an ordinary one landing at the same moment does not.
void TestWatchReserve()
{
    // Four of TestWall's walls (one collapse begins some 650 contacts), built awake so they slump by themselves too,
    // each hit by a ball.
    vphys::PhysWorld w;
    w.init(1024, 0);
    Floor(w);
    for (int wall = 0; wall < 4; wall++) {
        float z = -3 + 2.0f * wall;
        for (int row = 0; row < 10; row++) {
            for (int col = 0; col < 10; col++) {
                int c = w.addBox(0.049f, 0.049f, 0.049f, vphys::kDynamic);
                w.setPose(c, (col - 4.5f) * 0.1f, 0.05f + row * 0.1f, z, 0, 0, 0, 1);
                w.setMaterial(c, 0.2f, 0.3f, 0.6f);
            }
        }
        int ball = w.addSphere(0.1f, vphys::kDynamic);
        w.setPose(ball, 0, 0.3f, z + 1.0f, 0, 0, 0, 1);
        w.setMaterial(ball, 3, 0.3f, 0.6f);
        w.setVelocity(ball, 0, 0.5f, -8, 0, 0, 0);
    }
    int steps = 0;
    while (steps < 600 && (steps < 60 || w.droppedContacts() == 0)) {  // the balls are in the walls by then
        w.step(kDt, 1);  // not drained: the buffer fills
        steps++;
    }
    Check(w.droppedContacts() > 0, "reserve: a collapse not drained fills the buffer of ordinary contacts");
    int watchedBox = w.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
    w.setPose(watchedBox, 5, 0.3f, 8, 0, 0, 0, 1);
    w.watch(watchedBox, 1);
    int plainBox = w.addBox(0.05f, 0.05f, 0.05f, vphys::kDynamic);
    w.setPose(plainBox, -5, 0.3f, 8, 0, 0, 0, 1);
    for (int s = 0; s < 60; s++) {
        w.step(kDt, 1);
    }
    std::vector<float> buf(kRec * 1024 + 8, -12345.0f);
    int n = w.drainContacts(buf.data(), 1024);
    bool watchedSeen = false, plainSeen = false;
    for (int k = 0; k < n; k++) {
        watchedSeen = watchedSeen || Has(buf.data() + k * kRec, watchedBox);
        plainSeen = plainSeen || Has(buf.data() + k * kRec, plainBox);
    }
    std::printf("      reserve: buffer full after %d steps, %d records drained, %u dropped\n", steps, n,
                w.droppedContacts());
    Check(n >= 960 && n <= 1024 && buf[kRec * 1024] == -12345.0f, "reserve: 960 ordinary records, never more than 1024");
    Check(watchedSeen, "reserve: the watched body's landing is recorded during the collapse");
    Check(!plainSeen, "reserve: an ordinary body's landing at the same time is dropped");
}

void TestAngular()
{
    vphys::PhysWorld w;
    w.init(64, 0);
    w.setGravity(0);
    int b = w.addBox(0.1f, 0.1f, 0.1f, vphys::kDynamic);
    w.setPose(b, 0, 1, 0, 0, 0, 0, 1);
    w.setVelocity(b, 1, 2, 3, 0.5f, -1, 2);
    float v[6];
    Check(w.readVelocity(b, v, 6) && v[0] == 1 && v[1] == 2 && v[2] == 3 && v[3] == 0.5f && v[4] == -1 && v[5] == 2,
          "angular: readVelocity with 6 floats gives the set linear and angular velocity");
    float s3[4] = {-7, -7, -7, -7};
    Check(w.readVelocity(b, s3, 3) && s3[0] == 1 && s3[2] == 3 && s3[3] == -7, "angular: 3 floats get exactly 3");
    float s5[6] = {-7, -7, -7, -7, -7, -7};
    Check(w.readVelocity(b, s5, 5) && s5[2] == 3 && s5[3] == -7 && s5[4] == -7, "angular: 5 floats get 3 too");
    float s2[3] = {-7, -7, -7};
    Check(!w.readVelocity(b, s2, 2) && s2[0] == -7 && s2[1] == -7, "angular: under 3 floats nothing is written");
}

void TestExplode()
{
    vphys::PhysWorld w;
    w.init(64, 0);
    w.setGravity(0);
    auto box = [&](float x, float y, float z, int kind) {
        int i = w.addBox(0.05f, 0.05f, 0.05f, kind);
        w.setPose(i, x, y, z, 0, 0, 0, 1);
        return i;
    };
    int a = box(1, 0, 0, vphys::kDynamic);
    int heavy = w.addSphere(0.1f, vphys::kDynamic);
    w.setPose(heavy, 0, 2, 0, 0, 0, 0, 1);
    w.setMaterial(heavy, 5, 0.3f, 0.5f);
    int centre = box(0, 0, 0, vphys::kDynamic);
    int far = box(5, 0, 0, vphys::kDynamic);
    int wall = box(0, -1, 0, vphys::kStatic);
    int walker = box(0, 0, -1.5f, vphys::kCharacter);
    int shot = w.addSphere(0.03f, vphys::kProjectile);
    w.setPose(shot, -1, 0, 0, 0, 0, 0, 1);
    for (int i : {a, heavy, centre, far}) {
        w.sleep(i);
    }
    Check(w.explode(0, 0, 0, 0, 6) == 0, "explode: no radius, nothing pushed");
    int n = w.explode(0, 0, 0, 3, 6);
    auto vel = [&](int i, float x, float y, float z) {
        float v[3];
        return w.readVelocity(i, v) && std::fabs(v[0] - x) < 1e-3f && std::fabs(v[1] - y) < 1e-3f &&
               std::fabs(v[2] - z) < 1e-3f;
    };
    std::printf("      explode: %d bodies pushed, %d dynamic awake\n", n, w.awakeDynamic());
    Check(n == 5, "explode: returns the bodies within the radius (dynamic, character and projectile; not static)");
    Check(vel(a, 4, 0, 0), "explode: 1 m out of 3, strength 6: 4 m/s away");
    Check(vel(heavy, 0, 2, 0), "explode: the change is in velocity, whatever the mass (5 kg, 2 m: 2 m/s)");
    Check(vel(centre, 0, 6, 0), "explode: one at the centre goes straight up");
    Check(vel(walker, 0, 0, -3) && vel(shot, -4, 0, 0), "explode: a character and a projectile are pushed too");
    Check(vel(far, 0, 0, 0) && vel(wall, 0, 0, 0), "explode: outside the radius, and static bodies, untouched");
    Check(w.awakeDynamic() == 3, "explode: the sleeping bodies it pushed are awake");
    w.step(kDt, 1);
    float p[7];
    w.readPose(a, p);
    Check(p[0] > 1.05f, "explode: and they move on the next step");
}

}  // namespace

int main()
{
    TestLinearCastContact();
    TestRest();
    TestBound();
    TestContacts();
    TestDeterminism();
    TestWall();
    TestDiceFair();
    TestFloatCapacity();
    TestDrainBounded();
    TestSleepCap();
    TestParts();
    TestRolling();
    TestCharacter();
    TestProjectile();
    TestContactPoint();
    TestWatchReserve();
    TestAngular();
    TestExplode();
    std::printf(g_failures ? "%d FAILED\n" : "all passed\n", g_failures);
    return g_failures ? 1 : 0;
}
