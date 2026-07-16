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
//
// initial_prompt, when non-NULL and non-empty, is passed to whisper as the decoder's
// initial_prompt to bias recognition toward domain words/names (whisper caps it at
// ~224 tokens internally). Pass NULL for the default, unbiased behavior.
//
// language is an ISO 639-1 code ("en", "de", …) constraining the decoder, or "auto"
// to have whisper detect the spoken language per clip. Only multilingual models can
// honor anything but their own language — an English-only model such as base.en
// still decodes English whatever is passed. NULL means "en".
char *votelli_whisper_transcribe(votelli_ctx *ctx,
                                const float *samples,
                                int n_samples,
                                int n_threads,
                                const char *initial_prompt,
                                const char *language);

void votelli_whisper_free_string(char *s);
void votelli_whisper_free(votelli_ctx *ctx);

#ifdef __cplusplus
}
#endif

#endif // VOTELLI_WHISPER_H
