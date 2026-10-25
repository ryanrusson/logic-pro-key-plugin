// KeyFinder core C API (implemented in Rust, see core/src/ffi.rs).
#ifndef KEYFINDER_H
#define KEYFINDER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct KFAnalyzer KFAnalyzer;

enum {
    KF_MODE_BASS = 0,     // isolated bass / bass stem
    KF_MODE_GUITAR = 1,   // isolated guitar / "other" stem
    KF_MODE_FULL_MIX = 2, // full mix, vocals
    KF_MODE_AUTO = 3,     // most confident of the above (query only)
};

// All modes are analysed simultaneously; `mode` only selects which result
// to read, so switching never requires re-playing the audio.

typedef struct {
    int32_t tonic;    // pitch class, 0 = C
    int32_t is_minor;
    float score;      // profile correlation, -1..1
} KFKeyCandidate;

typedef struct {
    int32_t has_key;
    uint32_t mode;          // mode the result came from
    int32_t tonic;
    int32_t is_minor;
    float confidence;       // 0..1
    float tuning_cents;     // deviation from A440, -50..50
    float tonality;         // 0..1, how pitched the material is
    float seconds_analyzed;
    uint64_t voiced_frames;
    float chroma[12];       // normalised, index 0 = C
    KFKeyCandidate candidates[4]; // best first
} KFKeyResult;

KFAnalyzer *kf_analyzer_new(double sample_rate);
void kf_analyzer_free(KFAnalyzer *a);

// Realtime-safe: wait-free, no locks, no allocation. Render thread only.
// `right` may be NULL for mono. Returns frames accepted (rest are dropped).
size_t kf_analyzer_push(const KFAnalyzer *a, const float *left, const float *right, size_t frames);

// Background thread: drain buffered audio and update the analysis.
size_t kf_analyzer_process(const KFAnalyzer *a);

// Any non-realtime thread. Returns has_key.
int32_t kf_analyzer_result(const KFAnalyzer *a, uint32_t mode, KFKeyResult *out);

// Applied on the next kf_analyzer_process. sample_rate <= 0 keeps the
// current rate.
void kf_analyzer_reset(const KFAnalyzer *a, double sample_rate);
void kf_analyzer_set_listening(const KFAnalyzer *a, int32_t on);
uint64_t kf_analyzer_dropped_samples(const KFAnalyzer *a);

// Offline analysis of a whole mono buffer. Returns has_key.
int32_t kf_analyze_buffer(const float *mono, size_t n, double sample_rate, uint32_t mode, KFKeyResult *out);

// Static string, do not free.
const char *kf_note_name(int32_t pitch_class);

#ifdef __cplusplus
}
#endif

#endif
