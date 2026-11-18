// Host test for entry/src/main/cpp/phys_stepper.h, the thread the physics step runs on. No phone, no Jolt.
//
//   g++ -std=c++17 -Wall -Wextra -Werror -pthread -I entry/src/main/cpp tools/phys-stepper-test.cpp -o /tmp/t && /tmp/t
//
// Under ThreadSanitizer (recent kernels need the setarch):
//   g++ -std=c++17 -g -fsanitize=thread -pthread -I entry/src/main/cpp tools/phys-stepper-test.cpp -o /tmp/t-tsan
//   setarch "$(uname -m)" -R /tmp/t-tsan
//
// The "world" here is a plain struct with no lock: the test is that begin/wait/end alone keep the step thread and the
// caller from touching it at once, which TSan would report, and that every job runs exactly once, in order.

#include "phys_stepper.h"

#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

namespace {

int failures = 0;

void Check(bool ok, const char *what)
{
    if (!ok) {
        std::fprintf(stderr, "FAIL: %s\n", what);
        failures++;
    }
}

struct World {
    long steps = 0;
    long bodies = 0;
    std::vector<long> order;
};

}  // namespace

int main()
{
    {
        vphys::StepRunner runner;
        Check(runner.end() == 0, "end with nothing run is 0 ms");
        runner.wait();  // nothing in flight: returns at once
    }
    {
        // A frame loop: begin a step, then (as the next frame does) wait, touch the world, and begin again.
        vphys::StepRunner runner;
        World world;
        for (long f = 0; f < 2000; f++) {
            runner.wait();
            world.bodies += 1;  // what apply does between frames, after the step in flight
            Check(world.steps == f, "every step begun before has finished by wait");
            runner.begin([&world, f] {
                world.order.push_back(f);
                world.steps += 1;
            });
            if (f % 7 == 0) {
                std::this_thread::yield();
            }
        }
        double ms = runner.end();
        Check(world.steps == 2000, "2000 steps ran");
        Check(ms >= 0, "end gives the time taken");
        bool inOrder = world.order.size() == 2000;
        for (size_t i = 0; inOrder && i < world.order.size(); i++) {
            inOrder = world.order[i] == static_cast<long>(i);
        }
        Check(inOrder, "steps ran once each, in order");
        Check(runner.end() == 0, "a second end has nothing left to report");
    }
    {
        // begin twice without wait: the second waits for the first.
        vphys::StepRunner runner;
        World world;
        runner.begin([&world] {
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            world.steps = 1;
        });
        runner.begin([&world] { world.steps = world.steps * 10 + 2; });
        double ms = runner.end();
        Check(world.steps == 12, "a begin after a begin runs after it");
        Check(ms >= 15, "end sums the time of every job since the last end");
    }
    {
        // Destroyed with a job in flight: the destructor lets it finish.
        World world;
        {
            vphys::StepRunner runner;
            runner.begin([&world] {
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
                world.steps = 7;
            });
        }
        Check(world.steps == 7, "the job in flight finishes before the runner goes");
    }
    if (failures > 0) {
        std::fprintf(stderr, "phys-stepper-test: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("phys-stepper-test ok\n");
    return 0;
}
