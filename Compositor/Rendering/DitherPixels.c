#include "DitherPixels.h"
#include <math.h>
#include <stdlib.h>
#include <dispatch/dispatch.h>

static inline float clamp01(float v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

// Runs `body` over `count` items split into a few runs per core, each a (start, end) range, all at once.
static void in_bands(size_t count, void (^body)(size_t start, size_t end)) {
    size_t bands = count < 64 ? 1 : 32, size = (count + bands - 1) / bands;
    dispatch_apply(bands, DISPATCH_APPLY_AUTO, ^(size_t band) {
        size_t start = band * size, end = start + size < count ? start + size : count;
        if (start < end) body(start, end);
    });
}

// Density darkens (positive) or lightens as a gamma, so black and white stay put; contrast pivots on mid gray.
static inline float adjust_tone(float v, float gamma, float contrast) {
    v = powf(clamp01(v), gamma);
    return clamp01((v - 0.5f) * contrast + 0.5f);
}

// One error-diffusion kernel: neighbors to the right on this row and below, with their weights over `divisor`.
typedef struct { int dx, dy, weight; } Tap;
typedef struct { const Tap *taps; int count; float divisor; } Kernel;

static const Tap atkinson[] = { {1,0,1}, {2,0,1}, {-1,1,1}, {0,1,1}, {1,1,1}, {0,2,1} };
static const Tap floyd[] = { {1,0,7}, {-1,1,3}, {0,1,5}, {1,1,1} };

// Atkinson passes on only six eighths of the error, which is what gives the Mac's crisp, contrasty look.
static Kernel kernel_for(int style) {
    return style == DITHER_ATKINSON ? (Kernel){ atkinson, 6, 8 } : (Kernel){ floyd, 4, 16 };
}

static inline float quantize(float v, int levels) {
    float steps = (float)(levels - 1);
    return roundf(clamp01(v) * steps) / steps;
}

// Diffuses each plane in serpentine order, so the error's drift doesn't streak to one side.
static void diffuse(float *plane, const uint8_t *alpha, size_t width, size_t height, const DitherParams *p) {
    Kernel k = kernel_for(p->style);
    for (size_t y = 0; y < height; ++y) {
        int reverse = (int)(y & 1);
        for (size_t i = 0; i < width; ++i) {
            size_t x = reverse ? width - 1 - i : i;
            size_t at = y * width + x;
            if (!alpha[at]) continue;
            float old = plane[at], q = quantize(old, p->levels);
            plane[at] = q;
            float error = (old - q) * p->diffusion / k.divisor;
            for (int t = 0; t < k.count; ++t) {
                long nx = (long)x + (reverse ? -k.taps[t].dx : k.taps[t].dx), ny = (long)y + k.taps[t].dy;
                if (nx < 0 || nx >= (long)width || ny >= (long)height) continue;
                plane[(size_t)ny * width + (size_t)nx] += error * (float)k.taps[t].weight;
            }
        }
    }
}

static const uint8_t bayer8[64] = {
     0, 32,  8, 40,  2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41, 51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37, 63, 31, 55, 23, 61, 29, 53, 21,
};

static inline float ordered_threshold(int style, size_t x, size_t y) {
    switch (style) {
    case DITHER_BAYER_2: { static const uint8_t m[4] = { 0, 2, 3, 1 }; return ((float)m[(y & 1) * 2 + (x & 1)] + 0.5f) / 4; }
    case DITHER_BAYER_4: {
        static const uint8_t m[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
        return ((float)m[(y & 3) * 4 + (x & 3)] + 0.5f) / 16;
    }
    default: return ((float)bayer8[(y & 7) * 8 + (x & 7)] + 0.5f) / 64;
    }
}

static inline float ordered(float v, float threshold, int levels) {
    float steps = (float)(levels - 1);
    float q = floorf(clamp01(v) * steps + threshold);
    return (q > steps ? steps : q) / steps;
}

static inline float spot(int style, float u, float v) {
    float au = fabsf(u), av = fabsf(v);
    switch (style) {
    case DITHER_DOTS: return 3.14159265f * (u * u + v * v);
    case DITHER_LINES: return av * 2;
    default: return au + av;
    }
}

static const uint8_t patterns[][8] = {
    { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
    { 0x80, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00 },
    { 0x88, 0x00, 0x22, 0x00, 0x88, 0x00, 0x22, 0x00 },
    { 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01 },
    { 0x88, 0x22, 0x88, 0x22, 0x88, 0x22, 0x88, 0x22 },
    { 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00 },
    { 0x11, 0x22, 0x44, 0x88, 0x11, 0x22, 0x44, 0x88 },
    { 0xAA, 0x00, 0xAA, 0x00, 0xAA, 0x00, 0xAA, 0x00 },
    { 0x88, 0x55, 0x22, 0x55, 0x88, 0x55, 0x22, 0x55 },
    { 0xFF, 0x80, 0x80, 0x80, 0xFF, 0x08, 0x08, 0x08 },
    { 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55 },
    { 0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81 },
    { 0x77, 0xAA, 0xDD, 0xAA, 0x77, 0xAA, 0xDD, 0xAA },
    { 0xEE, 0xDD, 0xBB, 0x77, 0xEE, 0xDD, 0xBB, 0x77 },
    { 0x77, 0xFF, 0xDD, 0xFF, 0x77, 0xFF, 0xDD, 0xFF },
    { 0x7F, 0xFF, 0xFF, 0xFF, 0xF7, 0xFF, 0xFF, 0xFF },
    { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
};
static const int patternCount = (int)(sizeof patterns / sizeof patterns[0]);

static inline void write_pixel(uint8_t *px, float r, float g, float b) {
    float a = (float)px[3] / 255.0f;
    px[0] = (uint8_t)lroundf(clamp01(r) * a * 255.0f);
    px[1] = (uint8_t)lroundf(clamp01(g) * a * 255.0f);
    px[2] = (uint8_t)lroundf(clamp01(b) * a * 255.0f);
}

int dither_apply(uint8_t *rgba, size_t width, size_t height, size_t stride, const DitherParams *p) {
    size_t count = width * height;
    if (!count) return 1;
    int planes = p->originalColors ? 3 : 1;
    float *tone = malloc(count * sizeof(float) * (size_t)planes);
    uint8_t *alpha = malloc(count);
    float *source = p->originalColors ? malloc(count * sizeof(float) * 3) : NULL;
    if (!tone || !alpha || (p->originalColors && !source)) { free(tone); free(alpha); free(source); return 0; }
    float gamma = exp2f(p->density * 1.5f);
    float contrast = p->contrast >= 0 ? 1.0f / (1.0f - 0.95f * p->contrast) : 1.0f + p->contrast;
    in_bands(height, ^(size_t first, size_t last) {
        for (size_t y = first; y < last; ++y) {
            const uint8_t *row = rgba + y * stride;
            for (size_t x = 0; x < width; ++x) {
                const uint8_t *px = row + x * 4;
                size_t at = y * width + x;
                alpha[at] = px[3];
                float r = 0, g = 0, b = 0;
                if (px[3]) {
                    float scale = 1.0f / (float)px[3];
                    r = px[0] * scale; g = px[1] * scale; b = px[2] * scale;
                }
                if (p->originalColors) {
                    tone[at] = adjust_tone(r, gamma, contrast);
                    tone[count + at] = adjust_tone(g, gamma, contrast);
                    tone[2 * count + at] = adjust_tone(b, gamma, contrast);
                    source[at * 3] = r; source[at * 3 + 1] = g; source[at * 3 + 2] = b;
                } else {
                    tone[at] = adjust_tone(0.2126f * r + 0.7152f * g + 0.0722f * b, gamma, contrast);
                }
            }
        }
    });
    free(tone); free(alpha); free(source);
    return 1;
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
