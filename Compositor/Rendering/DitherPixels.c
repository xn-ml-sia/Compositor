#include "DitherPixels.h"
#include <math.h>
#include <stdlib.h>
#include <dispatch/dispatch.h>

static inline float clamp01(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

static inline void write_pixel(uint8_t *px, float r, float g, float b) {
    float a = (float)px[3] / 255.0f;
    px[0] = (uint8_t)lroundf(clamp01(r) * a * 255.0f);
    px[1] = (uint8_t)lroundf(clamp01(g) * a * 255.0f);
    px[2] = (uint8_t)lroundf(clamp01(b) * a * 255.0f);
}

void dither_dots(uint8_t *rgba, size_t width, size_t height, size_t stride, int block, const uint8_t *gap) {
    if (block < 2) return;
    float radius = (float)block * 0.42f, middle = (float)block / 2;
    for (size_t y = 0; y < height; ++y) {
        uint8_t *row = rgba + y * stride;
        float dy = (float)(y % (size_t)block) + 0.5f - middle;
        for (size_t x = 0; x < width; ++x) {
            uint8_t *px = row + x * 4;
            if (!px[3]) continue;
            float dx = (float)(x % (size_t)block) + 0.5f - middle;
            float cover = clamp01(radius - sqrtf(dx * dx + dy * dy) + 0.5f);
            if (cover >= 1) continue;
            for (int c = 0; c < 3; ++c)
                px[c] = (uint8_t)lroundf((float)px[c] * cover + (float)gap[c] * (float)px[3] / 255.0f * (1 - cover));
        }
    }
}

void dither_glow(uint8_t *rgba, const uint8_t *glow, size_t width, size_t height, size_t stride, float amount) {
    in_bands(height, ^(size_t first, size_t last) {
        for (size_t y = first; y < last; ++y) {
            uint8_t *row = rgba + y * stride;
            const uint8_t *light = glow + y * stride;
            for (size_t x = 0; x < width * 4; x += 4) {
                float a = row[x + 3];
                for (int c = 0; c < 3; ++c) {
                    float v = (float)row[x + c] + (float)light[x + c] * amount * a / 255.0f;
                    row[x + c] = (uint8_t)lroundf(v > a ? a : v);
                }
            }
        }
    });
}
