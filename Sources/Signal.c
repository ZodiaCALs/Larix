#include "Signal.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

enum { Capacity = 32768 };
typedef struct { double b0, b1, b2, a1, a2; } Biquad;
typedef struct { double z1, z2; } History;
typedef struct {
    Biquad filters[LX_BANDS];
    History history[LX_BANDS][2];
    float gains[LX_BANDS];
} FilterBank;
struct LXSignal {
    float samples[Capacity][2];
    _Atomic uint32_t written, read;
    _Atomic float gain, bands[LX_BANDS], peak;
    _Atomic unsigned revision;
    unsigned appliedRevision;
    FilterBank banks[2];
    unsigned activeBank, fadeLeft, fadeLength;
    double sourceRate, outputRate, fraction, smoothGain, gainStep;
    unsigned target;
    bool primed;
};

double LXBandFrequency(unsigned band) {
    static const double frequencies[] = {80, 250, 1000, 4000, 12000};
    return frequencies[band < LX_BANDS ? band : LX_BANDS - 1];
}

bool LXBandAvailable(unsigned band, double rate) {
    return band < LX_BANDS && LXBandFrequency(band) < rate * 0.5;
}

static Biquad bell(double frequency, double rate, float gain) {
    if (gain == 0) return (Biquad){.b0 = 1};
    double w = 2 * M_PI * frequency / rate;
    double a = pow(10, gain / 40.0), alpha = sin(w) / (2 * 0.85);
    double scale = 1 / (1 + alpha / a);
    return (Biquad){(1 + alpha * a) * scale, -2 * cos(w) * scale,
                    (1 - alpha * a) * scale, -2 * cos(w) * scale, (1 - alpha / a) * scale};
}

static double magnitudeSquared(double b0, double b1, double b2, double cosW, double sinW) {
    // Rotate the complex response by one sample of phase, preserving its magnitude.
    double re = (b0 + b2) * cosW + b1;
    double im = (b0 - b2) * sinW;
    return re * re + im * im;
}

void LXResponseCurveDB(double rate, const float gains[LX_BANDS], const double *frequencies,
                       double *decibels, unsigned count) {
    Biquad filters[LX_BANDS];
    unsigned active = 0;
    for (int i = 0; i < LX_BANDS; i++) {
        if (gains[i] != 0 && LXBandAvailable(i, rate))
            filters[active++] = bell(LXBandFrequency(i), rate, gains[i]);
    }
    if (!active) {
        memset(decibels, 0, count * sizeof(*decibels));
        return;
    }
    for (unsigned i = 0; i < count; i++) {
        double w = 2 * M_PI * frequencies[i] / rate;
        double cosW = cos(w), sinW = sin(w), power = 1;
        for (unsigned j = 0; j < active; j++) {
            Biquad b = filters[j];
            power *= magnitudeSquared(b.b0, b.b1, b.b2, cosW, sinW) /
                     magnitudeSquared(1, b.a1, b.a2, cosW, sinW);
        }
        decibels[i] = 10 * log10(power);
    }
}

double LXResponseDB(double frequency, double rate, const float gains[LX_BANDS]) {
    double db;
    LXResponseCurveDB(rate, gains, &frequency, &db, 1);
    return db;
}

LXSignal *LXSignalCreate(double sourceRate, double outputRate) {
    if (!(sourceRate >= 8000 && sourceRate <= 384000 &&
          outputRate >= 8000 && outputRate <= 384000)) return NULL;
    LXSignal *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->sourceRate = sourceRate;
    s->outputRate = outputRate;
    s->target = (unsigned)fmin(Capacity / 4, fmax(512, sourceRate * 0.028));
    s->gainStep = 1 - exp(-1 / (outputRate * 0.004));
    atomic_init(&s->gain, 1);
    atomic_init(&s->written, 0);
    atomic_init(&s->read, 0);
    atomic_init(&s->peak, 0);
    atomic_init(&s->revision, 0);
    s->fadeLength = (unsigned)lround(outputRate * 0.015);
    for (int i = 0; i < LX_BANDS; i++) {
        atomic_init(&s->bands[i], 0);
        s->banks[0].filters[i].b0 = 1;
    }
    return s;
}

void LXSignalDestroy(LXSignal *s) { free(s); }

void LXSignalSet(LXSignal *s, float volume, bool muted, const float gains[LX_BANDS]) {
    atomic_store(&s->gain, muted ? 0 : fminf(1, fmaxf(0, volume)));
    // Single control-queue writer. The renderer skips an incomplete preset without waiting.
    atomic_fetch_add(&s->revision, 1);
    for (int i = 0; i < LX_BANDS; i++)
        atomic_store(&s->bands[i], fminf(12, fmaxf(-12, gains[i])));
    atomic_fetch_add(&s->revision, 1);
}

static void updateFilters(LXSignal *s) {
    unsigned revision = atomic_load(&s->revision);
    if (s->fadeLeft || revision == s->appliedRevision || (revision & 1)) return;
    float gains[LX_BANDS];
    for (unsigned i = 0; i < LX_BANDS; i++)
        gains[i] = LXBandAvailable(i, s->outputRate) ? atomic_load(&s->bands[i]) : 0;
    if (revision != atomic_load(&s->revision)) return;
    s->appliedRevision = revision;
    FilterBank *from = &s->banks[s->activeBank], *to = &s->banks[1 - s->activeBank];
    unsigned first = 0;
    while (first < LX_BANDS && from->gains[first] == gains[first]) first++;
    if (first == LX_BANDS) return;

    *to = *from;
    // A changed stage also changes the input feeding every subsequent stage.
    for (unsigned i = first; i < LX_BANDS; i++) {
        to->filters[i] = bell(LXBandFrequency(i), s->outputRate, gains[i]);
        to->gains[i] = gains[i];
        memset(to->history[i], 0, sizeof(to->history[i]));
    }
    s->fadeLeft = s->fadeLength;
}

static double filterSample(FilterBank *bank, int channel, double x) {
    for (int j = 0; j < LX_BANDS; j++) {
        if (bank->gains[j] == 0) continue;
        Biquad f = bank->filters[j];
        History *h = &bank->history[j][channel];
        double y = f.b0 * x + h->z1;
        h->z1 = f.b1 * x - f.a1 * y + h->z2;
        h->z2 = f.b2 * x - f.a2 * y;
        x = y;
    }
    return x;
}

void LXSignalPush(LXSignal *s, const float *l, const float *r, unsigned stride, unsigned frames) {
    uint32_t write = atomic_load_explicit(&s->written, memory_order_relaxed);
    uint32_t used = write - atomic_load_explicit(&s->read, memory_order_acquire);
    if (frames > Capacity - used) frames = Capacity - used;
    for (unsigned i = 0; i < frames; i++) {
        float *dst = s->samples[(write + i) % Capacity];
        dst[0] = l[i * stride];
        dst[1] = r[i * stride];
    }
    atomic_store_explicit(&s->written, write + frames, memory_order_release);
}

void LXSignalRender(LXSignal *s, float *output, unsigned channels, unsigned frames) {
    uint32_t read = atomic_load_explicit(&s->read, memory_order_relaxed);
    uint32_t available = atomic_load_explicit(&s->written, memory_order_acquire) - read;
    memset(output, 0, frames * channels * sizeof(float));
    double ratio = s->sourceRate / s->outputRate;
    unsigned target = (unsigned)fmin(Capacity / 2, fmax(s->target, ceil(frames * ratio) + 2));
    // Re-prime after underrun. Drop stale data after a device stalls.
    if (available > target * 3) {
        read += available - target;
        available = target;
        s->fraction = 0;
    }
    if (!s->primed && available < target) {
        atomic_store(&s->peak, 0);
        return;
    }
    s->primed = true;
    // Independent input and output hardware clocks drift even at the same nominal rate.
    double error = ((double)available - target) / target;
    ratio *= 1 + fmax(-0.002, fmin(0.002, error * 0.001));
    updateFilters(s);
    float peak = 0, gain = atomic_load(&s->gain);
    for (unsigned i = 0; i < frames; i++) {
        unsigned advance = (unsigned)(s->fraction + ratio);
        if (available < 2 || advance > available) {
            s->primed = false;
            s->fraction = 0;
            break;
        }
        float *a = s->samples[read % Capacity], *b = s->samples[(read + 1) % Capacity];
        float stereo[2];
        double mix = 1 - (double)s->fadeLeft / s->fadeLength;
        s->smoothGain += (gain - s->smoothGain) * s->gainStep;
        for (int ch = 0; ch < 2; ch++) {
            double x = a[ch] + (b[ch] - a[ch]) * s->fraction;
            double y = filterSample(&s->banks[s->activeBank], ch, x);
            if (s->fadeLeft) {
                double next = filterSample(&s->banks[1 - s->activeBank], ch, x);
                y += (next - y) * mix;
            }
            stereo[ch] = (float)fmax(-1, fmin(1, y * s->smoothGain));
            peak = fmaxf(peak, fabsf(stereo[ch]));
        }
        if (s->fadeLeft && --s->fadeLeft == 0) s->activeBank = 1 - s->activeBank;
        if (channels == 1) output[i] = (stereo[0] + stereo[1]) * 0.5f;
        else { output[i * channels] = stereo[0]; output[i * channels + 1] = stereo[1]; }
        read += advance;
        available -= advance;
        s->fraction += ratio - advance;
    }
    atomic_store_explicit(&s->read, read, memory_order_release);
    atomic_store(&s->peak, fmaxf(peak, atomic_load(&s->peak) * expf(-(float)frames / (0.15f * s->outputRate))));
}

float LXSignalPeak(LXSignal *s) { return atomic_load(&s->peak); }
