/* Thin miniaudio wrapper.
   The SexC side calls audio_start / audio_get_level / audio_stop
   and stays unaware of ma_* internals. */

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <math.h>
#include <string.h>

static ma_device g_device;
static int       g_running = 0;

/* Single float updated by the audio thread, polled by the main thread.
   Aligned 32-bit float load/store is atomic on every platform that runs
   raylib, so for a visual smoothing read like this no locking is needed. */
static volatile float g_level = 0.0f;

static void on_capture(ma_device* dev, void* output, const void* input, ma_uint32 frames)
{
    (void)dev;
    (void)output;
    if (input == NULL || frames == 0) return;

    const float* samples = (const float*)input;
    float sum = 0.0f;
    for (ma_uint32 i = 0; i < frames; i++) {
        float s = samples[i];
        sum += s * s;
    }
    g_level = sqrtf(sum / (float)frames);
}

int audio_start(void)
{
    if (g_running) return 1;

    ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
    cfg.capture.format   = ma_format_f32;
    cfg.capture.channels = 1;
    cfg.sampleRate       = 48000;
    cfg.dataCallback     = on_capture;

    if (ma_device_init(NULL, &cfg, &g_device) != MA_SUCCESS) return 0;
    if (ma_device_start(&g_device) != MA_SUCCESS) {
        ma_device_uninit(&g_device);
        return 0;
    }
    g_running = 1;
    return 1;
}

float audio_get_level(void)
{
    return g_level;
}

void audio_stop(void)
{
    if (!g_running) return;
    ma_device_uninit(&g_device);
    g_running = 0;
}
