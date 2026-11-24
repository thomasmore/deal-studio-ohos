// Replay an exact selector request through the embedded C ABI, without installing an app.
// Cross-link against one model-bearing OHOS liblocal_jev.a; run each model separately.
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "local_jev.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <sys/resource.h>
#endif
#include <time.h>

static double now_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) { perror("clock_gettime"); exit(1); }
    return t.tv_sec * 1000.0 + t.tv_nsec / 1000000.0;
}
static void memory(long *rss, long *hwm) {
    *rss = *hwm = -1;
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) {
#ifdef __APPLE__
        struct rusage usage;
        if (getrusage(RUSAGE_SELF, &usage) == 0) *hwm = usage.ru_maxrss / 1024;
#endif
        return;
    }
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "VmRSS:", 6) == 0) (void)sscanf(line + 6, "%ld", rss);
        if (strncmp(line, "VmHWM:", 6) == 0) (void)sscanf(line + 6, "%ld", hwm);
    }
    fclose(f);
}
static void output(const char *kind, int iteration, double ms, const char *reply) {
    long rss, hwm;
    memory(&rss, &hwm);
    printf("{\"kind\":\"%s\",\"iteration\":%d,\"ms\":%.3f,\"rss_kib\":%ld,\"peak_rss_kib\":%ld,\"response\":%s}\n",
        kind, iteration, ms, rss, hwm, reply ? reply : "null");
    fflush(stdout);
}
int main(int argc, char **argv) {
    if (argc < 2 || argc > 4) {
        fprintf(stderr, "usage: device-bench REQUEST.json [REPEATS [serial|batched]]\n");
        return 2;
    }
    char *end = NULL;
    long repeats = argc >= 3 ? strtol(argv[2], &end, 10) : 3;
    if ((end && *end != '\0') || repeats < 1 || repeats > 20) return 2;
    int profile = argc == 4;
    uint32_t mode = LOCAL_JEV_BENCH_SERIAL;
    if (profile) {
        if (strcmp(argv[3], "batched") == 0) mode = LOCAL_JEV_BENCH_BATCHED;
        else if (strcmp(argv[3], "serial") != 0) {
            fprintf(stderr, "expected serial or batched\n");
            return 2;
        }
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror("request"); return 1; }
    if (fseek(f, 0, SEEK_END) != 0) return 1;
    long size = ftell(f);
    if (size <= 0 || size > 262144 || fseek(f, 0, SEEK_SET) != 0) return 1;
    char *body = malloc((size_t)size);
    if (!body || fread(body, 1, (size_t)size, f) != (size_t)size) return 1;
    fclose(f);
    if (local_jev_abi() != 1) return 1;
    double start = now_ms();
    char *status = local_jev_status();
    output("load", 0, now_ms() - start, status);
    int ready = status && strstr(status, "\"ready\":true");
    local_jev_free(status);
    if (!ready) { free(body); return 1; }
    for (int i = profile ? 0 : 1; i <= repeats; ++i) {
        start = now_ms();
        char *reply = profile
            ? local_jev_benchmark_decisions((const uint8_t *)body, (size_t)size, mode)
            : local_jev_experimental_decisions((const uint8_t *)body, (size_t)size);
        output(i == 0 ? "warmup" : "inference", i, now_ms() - start, reply);
        int ok = reply && strstr(reply, "\"status\":\"diagnostic\"");
        local_jev_free(reply);
        if (!ok) { free(body); return 1; }
    }
    free(body);
    return 0;
}
