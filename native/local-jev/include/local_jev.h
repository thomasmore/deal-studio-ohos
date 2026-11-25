#ifndef VERA_LOCAL_JEV_H
#define VERA_LOCAL_JEV_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t local_jev_abi(void);
// Input is UTF-8. Each returned string belongs to Rust until local_jev_free.
char *local_jev_predict(const uint8_t *data, size_t len);
// Experimental only. Returns logits and leaves the answer map empty.
char *local_jev_diagnostic_scores(const uint8_t *data, size_t len);
// Developer opt-in only: uncalibrated decisions with raw scores and diagnostics.
char *local_jev_experimental_decisions(const uint8_t *data, size_t len);
// Laya benchmark decisions plus phase timings and group lengths.
enum {
    LOCAL_JEV_BENCH_SERIAL = 0,
    LOCAL_JEV_BENCH_BATCHED = 1,
};
char *local_jev_benchmark_decisions(const uint8_t *data, size_t len, uint32_t mode);
// Loads and validates the bundle; call off the UI thread.
char *local_jev_status(void);
void local_jev_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
