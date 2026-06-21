#ifndef MURMUR_WHISPER_H
#define MURMUR_WHISPER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct murmur_ctx murmur_ctx;

// Load a ggml whisper model from disk. Returns NULL on failure.
// use_gpu enables the Metal backend.
murmur_ctx *murmur_whisper_init(const char *model_path, int use_gpu);

// Transcribe 16kHz mono float samples in [-1,1]. Returns a malloc'd, NUL-terminated
// UTF-8 string the caller must free with murmur_whisper_free_string. NULL on failure.
char *murmur_whisper_transcribe(murmur_ctx *ctx,
                                const float *samples,
                                int n_samples,
                                int n_threads);

void murmur_whisper_free_string(char *s);
void murmur_whisper_free(murmur_ctx *ctx);

#ifdef __cplusplus
}
#endif

#endif // MURMUR_WHISPER_H
