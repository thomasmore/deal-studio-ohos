// Host test for the physics world (entry/src/main/cpp/phys_world.h), single thread, against the
// same Jolt sources the phone build uses (fetch them first: see the top of
// entry/src/main/cpp/CMakeLists.txt).
//
//   cmake -S tools/phys-world-test -B /tmp/phys-world-test-build -DCMAKE_BUILD_TYPE=Release
//   cmake --build /tmp/phys-world-test-build -j && /tmp/phys-world-test-build/phys_world_test

#include "phys_world.h"

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
    float all[3 * 64];
    int total = 0;
    float speed = 0;
    bool pair = false;
    for (int i = 0; i < 90; i++) {
        w.step(kDt, 1);
        int n = w.drainContacts(all, 64);
        for (int k = 0; k < n; k++) {
            total++;
            speed = std::max(speed, all[k * 3 + 2]);
            pair = pair || (all[k * 3] == static_cast<float>(b) && all[k * 3 + 1] == static_cast<float>(f)) ||
                   (all[k * 3] == static_cast<float>(f) && all[k * 3 + 1] == static_cast<float>(b));
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
    float buf[3 * 1024];
    for (int i = 0; i < static_cast<int>(seconds * 60); i++) {
        w.step(kDt, 1);
        int n = w.drainContacts(buf, 1024);
        for (int k = 0; k < n; k++) {
            *hard += buf[k * 3 + 2] > 1.0f ? 1 : 0;
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
    std::vector<float> out(static_cast<size_t>(cap) * 3 + guard, -12345.0f);
    int most = 0;
    bool intact = true;
    uint32_t droppedBefore = w.droppedContacts();
    for (int s = 0; s < 120; s++) {
        w.step(kDt, 1);
        int n = w.drainContacts(out.data(), cap);
        most = std::max(most, n);
        for (int k = cap * 3; k < cap * 3 + guard; k++) {
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
}

}  // namespace

int main()
{
    TestRest();
    TestBound();
    TestContacts();
    TestDeterminism();
    TestWall();
    TestDiceFair();
    TestFloatCapacity();
    TestDrainBounded();
    TestSleepCap();
    std::printf(g_failures ? "%d FAILED\n" : "all passed\n", g_failures);
    return g_failures ? 1 : 0;
}
