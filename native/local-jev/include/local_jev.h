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
void local_jev_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
