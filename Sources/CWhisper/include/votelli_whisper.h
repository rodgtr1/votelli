#ifndef VOTELLI_WHISPER_H
#define VOTELLI_WHISPER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct votelli_ctx votelli_ctx;

// Load a ggml whisper model from disk. Returns NULL on failure.
// use_gpu enables the Metal backend.
votelli_ctx *votelli_whisper_init(const char *model_path, int use_gpu);

// Transcribe 16kHz mono float samples in [-1,1]. Returns a malloc'd, NUL-terminated
// UTF-8 string the caller must free with votelli_whisper_free_string. NULL on failure.
char *votelli_whisper_transcribe(votelli_ctx *ctx,
                                const float *samples,
                                int n_samples,
                                int n_threads);

void votelli_whisper_free_string(char *s);
void votelli_whisper_free(votelli_ctx *ctx);

#ifdef __cplusplus
}
#endif

#endif // VOTELLI_WHISPER_H
