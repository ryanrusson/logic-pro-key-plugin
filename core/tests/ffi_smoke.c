// Links against the Rust staticlib through the public header to verify the
// C ABI (struct layout, symbol names) matches what Swift will see.
#include "keyfinder.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    const double sr = 48000.0;
    const size_t n = (size_t)(sr * 12);
    float *l = malloc(n * sizeof(float)), *r = malloc(n * sizeof(float));
    // G - C - D - G (I-IV-V-I) triads with harmonics, one chord per second.
    const double chords[4][3] = {{196.00, 246.94, 293.66}, {130.81, 164.81, 196.00},
                                 {146.83, 185.00, 220.00}, {196.00, 246.94, 293.66}};
    for (size_t i = 0; i < n; i++) {
        double t = i / sr, s = 0;
        const double *c = chords[(size_t)t % 4];
        for (int k = 0; k < 3; k++)
            for (int h = 1; h <= 6; h++) s += sin(2 * M_PI * c[k] * h * t) / h;
        l[i] = r[i] = (float)(0.08 * s);
    }

    KFAnalyzer *a = kf_analyzer_new(sr);
    if (!a) return 1;
    for (size_t off = 0; off < n; off += 256) {
        size_t m = n - off < 256 ? n - off : 256;
        if (kf_analyzer_push(a, l + off, r + off, m) != m) return 2;
        if (off % 4096 == 0) kf_analyzer_process(a);
    }
    kf_analyzer_process(a);

    KFKeyResult res;
    memset(&res, 0xff, sizeof res);
    if (!kf_analyzer_result(a, KF_MODE_AUTO, &res)) return 3;
    printf("%s %s conf=%.2f tuning=%+.1fc tonality=%.2f mode=%u secs=%.1f\n", kf_note_name(res.tonic),
           res.is_minor ? "minor" : "major", res.confidence, res.tuning_cents, res.tonality, res.mode,
           res.seconds_analyzed);
    if (res.tonic != 7 || res.is_minor || res.candidates[0].tonic != 7) return 4;
    if (fabsf(res.seconds_analyzed - 12.0f) > 0.1f) return 5;

    kf_analyzer_reset(a, 0);
    kf_analyzer_process(a);
    if (kf_analyzer_result(a, KF_MODE_GUITAR, &res)) return 6;
    kf_analyzer_free(a);

    if (!kf_analyze_buffer(l, n, sr, KF_MODE_GUITAR, &res) || res.tonic != 7) return 7;
    puts("ffi ok");
    return 0;
}
