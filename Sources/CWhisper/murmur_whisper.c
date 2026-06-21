#include "murmur_whisper.h"
#include "whisper.h"

#include <stdlib.h>
#include <string.h>

struct murmur_ctx {
    struct whisper_context *wctx;
};

murmur_ctx *murmur_whisper_init(const char *model_path, int use_gpu) {
    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = use_gpu ? true : false;
    cparams.flash_attn = true;

    struct whisper_context *wctx =
        whisper_init_from_file_with_params(model_path, cparams);
    if (!wctx) {
        return NULL;
    }

    murmur_ctx *ctx = (murmur_ctx *)calloc(1, sizeof(murmur_ctx));
    if (!ctx) {
        whisper_free(wctx);
        return NULL;
    }
    ctx->wctx = wctx;
    return ctx;
}

char *murmur_whisper_transcribe(murmur_ctx *ctx,
                                const float *samples,
                                int n_samples,
                                int n_threads) {
    if (!ctx || !ctx->wctx || !samples || n_samples <= 0) {
        return NULL;
    }

    struct whisper_full_params params =
        whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.no_context = true;
    params.suppress_blank = true;
    params.single_segment = false;
    params.language = "en";
    params.n_threads = n_threads > 0 ? n_threads : 4;

    if (whisper_full(ctx->wctx, params, samples, n_samples) != 0) {
        return NULL;
    }

    int n_segments = whisper_full_n_segments(ctx->wctx);
    size_t len = 0;
    char *out = (char *)malloc(1);
    if (!out) {
        return NULL;
    }
    out[0] = '\0';

    for (int i = 0; i < n_segments; i++) {
        const char *seg = whisper_full_get_segment_text(ctx->wctx, i);
        if (!seg) {
            continue;
        }
        size_t sl = strlen(seg);
        char *grown = (char *)realloc(out, len + sl + 1);
        if (!grown) {
            free(out);
            return NULL;
        }
        out = grown;
        memcpy(out + len, seg, sl);
        len += sl;
        out[len] = '\0';
    }

    return out;
}

void murmur_whisper_free_string(char *s) {
    free(s);
}

void murmur_whisper_free(murmur_ctx *ctx) {
    if (!ctx) {
        return;
    }
    if (ctx->wctx) {
        whisper_free(ctx->wctx);
    }
    free(ctx);
}
