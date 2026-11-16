// Physics, the step off the UI thread: one job at a time on a thread of its own.
//
// The world's step used to run inside the frame callback, on the UI thread, and with 300 bodies tumbling it took the
// frame past its budget (3-4 ms of a 16.7 ms frame on a 120 Hz panel turned 2 vsyncs into 3: 40 fps). Now a frame hands
// the step to this thread and returns; the next frame collects it (end) before it reads the poses. Every other use of
// the world -- adding a body, a kick, reading a pose -- waits for a step in flight first (wait), so the world is only
// ever touched by one thread at a time and needs no lock of its own.
//
// Header-only and free of Jolt, so tools/phys-stepper-test.cpp runs it on the host under ThreadSanitizer.

#pragma once

#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <thread>
#include <utility>

namespace vphys {

class StepRunner {
public:
    StepRunner() : thread_([this] { Loop(); }) {}
    ~StepRunner()
    {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            quit_ = true;
        }
        wake_.notify_all();
        thread_.join();
    }
    StepRunner(const StepRunner &) = delete;
    StepRunner &operator=(const StepRunner &) = delete;

    // Runs job on the thread, after any job still in flight; returns at once.
    void begin(std::function<void()> job)
    {
        std::unique_lock<std::mutex> lock(mutex_);
        done_.wait(lock, [this] { return !busy_; });
        job_ = std::move(job);
        busy_ = true;
        lock.unlock();
        wake_.notify_all();
    }

    // Waits for the job in flight, if any; the time it took stays for end().
    void wait()
    {
        std::unique_lock<std::mutex> lock(mutex_);
        done_.wait(lock, [this] { return !busy_; });
    }

    // Waits for the job in flight and returns the milliseconds the jobs finished since the last end() took.
    double end()
    {
        std::unique_lock<std::mutex> lock(mutex_);
        done_.wait(lock, [this] { return !busy_; });
        double ms = ms_;
        ms_ = 0;
        return ms;
    }

private:
    void Loop()
    {
        std::unique_lock<std::mutex> lock(mutex_);
        for (;;) {
            wake_.wait(lock, [this] { return quit_ || (busy_ && job_); });
            if (!(busy_ && job_)) {
                return;  // quit, nothing left to run
            }
            std::function<void()> job = std::move(job_);
            job_ = nullptr;
            lock.unlock();
            auto t0 = std::chrono::steady_clock::now();
            job();
            auto t1 = std::chrono::steady_clock::now();
            lock.lock();
            ms_ += std::chrono::duration<double, std::milli>(t1 - t0).count();
            busy_ = false;
            done_.notify_all();
        }
    }

    std::mutex mutex_;
    std::condition_variable wake_;  // a job to run, or quit
    std::condition_variable done_;  // the job in flight finished
    std::function<void()> job_;
    bool busy_ = false;  // a job handed over and not finished
    bool quit_ = false;
    double ms_ = 0;
    std::thread thread_;  // last: started once everything it uses is built
};

}  // namespace vphys
