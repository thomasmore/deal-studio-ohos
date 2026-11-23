#include "local_jev.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int has_finite_score(const char *scores, const char *key) {
    const char *value = strstr(scores, key);
    if (!value) return 0;
    value += strlen(key);
    char *end = NULL;
    const double score = strtod(value, &end);
    return end != value && (*end == ',' || *end == '}') && isfinite(score);
}

static int check(const char *name, char *reply, const char *expected, int diagnostic) {
    const char *match = reply ? strstr(reply, expected) : NULL;
    const int ok = match && strstr(reply, "\"answers\":{}") &&
        (!diagnostic || (has_finite_score(match, "\"chart\":") && has_finite_score(match, "\"timer\":")));
    if (reply) {
        printf("%s %s\n", name, reply);
        local_jev_free(reply);
    }
    return ok;
}

int main(void) {
    static const uint8_t request[] =
        "{\"state\":\"Track expenses by category.\",\"questions\":{"
        "\"widget\":{\"type\":\"choice\",\"instructions\":\"Pick the main widget.\","
        "\"criteria\":{\"chart\":\"Category totals\",\"timer\":\"Countdown\"}}}}";
    if (local_jev_abi() != 1) return 1;
    if (!check("predict", local_jev_predict(request, sizeof(request) - 1),
               "\"reason\":\"laya_not_human_calibrated\"", 0)) return 1;
    for (int i = 0; i < 2; ++i) {
        if (!check("diagnostic", local_jev_diagnostic_scores(request, sizeof(request) - 1),
                   "\"scores\":{\"widget\":{\"logits\":{", 1)) return 1;
    }
    return 0;
}
