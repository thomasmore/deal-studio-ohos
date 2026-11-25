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

int main(int argc, char **argv) {
    const int laya = argc == 2 && strcmp(argv[1], "--laya") == 0;
    if (argc != 1 && !laya) return 1;
    static const uint8_t request[] =
        "{\"state\":\"Track expenses by category.\",\"questions\":{"
        "\"widget\":{\"type\":\"choice\",\"instructions\":\"Pick the main widget.\","
        "\"criteria\":{\"chart\":\"Category totals\",\"timer\":\"Countdown\"}}}}";
    if (local_jev_abi() != 1) return 1;
    char *status = local_jev_status();
    const int ready = status && strstr(status, "\"ready\":true") &&
        (laya || (strstr(status, "\"model\":\"mmbert-shared-state-q8-experimental\"") &&
                  strstr(status, "\"manifestSha256\":\"4d40ff9d998cb139df51104bcf3c3d9a23f8bf609bc74c25819b5017e1eec7d5\"")));
    if (status) {
        printf("status %s\n", status);
        local_jev_free(status);
    }
    if (!ready) return 1;

    if (!check("predict", local_jev_predict(request, sizeof(request) - 1),
               laya ? "\"reason\":\"laya_not_human_calibrated\"" :
                      "\"reason\":\"shared_state_not_human_calibrated\"", 0)) return 1;
    for (int i = 0; i < 2; ++i) {
        if (!check("diagnostic", local_jev_diagnostic_scores(request, sizeof(request) - 1),
                   "\"scores\":{\"widget\":{\"logits\":{", 1)) return 1;
    }
    char *experimental = local_jev_experimental_decisions(request, sizeof(request) - 1);
    int ok = experimental && strstr(experimental, "\"diagnostic\":true") &&
        strstr(experimental, "\"productionAllowed\":false") &&
        (laya || strstr(experimental, "\"model\":\"mmbert-shared-state-q8-experimental\"")) &&
        strstr(experimental, "\"probabilities\":{") &&
        !strstr(experimental, "\"answers\":{}");
    if (experimental) { printf("experimental %s\n", experimental); local_jev_free(experimental); }
    return ok ? 0 : 1;
}
