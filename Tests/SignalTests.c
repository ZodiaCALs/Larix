#include "../Sources/Signal.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

// Drive the real capture/render boundary using two independent simulated device rates.
static double tone(double sourceRate, double outputRate, double hz, float volume, bool muted, float *gains) {
    LXSignal *signal = LXSignalCreate(sourceRate, outputRate);
    assert(signal);
    LXSignalSet(signal, volume, muted, gains);
    float input[2048], output[512];
    unsigned long position = 0;
    double energy = 0;
    for (unsigned block = 0; block < 380; block++) {
        unsigned long end = lround((block + 1) * 256 * sourceRate / outputRate);
        unsigned count = (unsigned)(end - position);
        assert(count * 2 <= 2048);
        for (unsigned i = 0; i < count; i++) {
            input[i * 2] = 0.12f * sin(2 * M_PI * hz * (position + i) / sourceRate);
            input[i * 2 + 1] = -input[i * 2];
        }
        LXSignalPush(signal, input, input + 1, 2, count);
        LXSignalRender(signal, output, 2, 256);
        for (unsigned frame = 0; frame < 256; frame++) {
            assert(isfinite(output[frame * 2]));
            assert(fabsf(output[2 * frame] + output[2 * frame + 1]) < 1e-6);
            if (block >= 80) energy += output[2 * frame] * output[2 * frame];
        }
        position = end;
    }
    assert(isfinite(LXSignalPeak(signal)) && LXSignalPeak(signal) <= 1);
    LXSignalDestroy(signal);
    return sqrt(energy / (300 * 256));
}

static void testLiveEQ(void) {
    // The same input and clock in three routes isolate changes made by the live EQ.
    LXSignal *live = LXSignalCreate(48000, 48000);
    LXSignal *boosted = LXSignalCreate(48000, 48000);
    LXSignal *dry = LXSignalCreate(48000, 48000);
    float boost[LX_BANDS] = {12, 0, 0, 0, 0}, flat[LX_BANDS] = {0};
    LXSignalSet(live, 1, false, boost);
    LXSignalSet(boosted, 1, false, boost);
    for (unsigned block = 0; block < 150; block++) {
        float input[128], wet[128], before[128], after[128];
        for (unsigned i = 0; i < 128; i++)
            input[i] = 0.12f * cos(2 * M_PI * 80 * (128 * block + i) / 48000);
        if (block == 100 || block == 122) LXSignalSet(live, 1, false, flat);
        if (block == 120) LXSignalSet(live, 1, false, boost);
        LXSignalPush(live, input, input, 1, 128);
        LXSignalPush(boosted, input, input, 1, 128);
        LXSignalPush(dry, input, input, 1, 128);
        LXSignalRender(live, wet, 1, 128);
        LXSignalRender(boosted, before, 1, 128);
        LXSignalRender(dry, after, 1, 128);
        for (unsigned i = 0; i < 128; i++) {
            if (block >= 100 && block < 106) {
                unsigned elapsed = (block - 100) * 128 + i;
                double blend = fmin(1, elapsed / 720.0);
                double expected = before[i] + blend * (after[i] - before[i]);
                assert(fabs(wet[i] - expected) < 1e-6);
            }
            // The second bypass arrives while the previous transition is in progress.
            if ((block >= 106 && block < 120) || block >= 133) assert(wet[i] == after[i]);
        }
    }
    LXSignalDestroy(dry);
    LXSignalDestroy(boosted);
    LXSignalDestroy(live);
}

int main(void) {
    float flat[LX_BANDS] = {0};
    double reference = tone(48000, 48000, 1000, 1, false, flat);
    assert(fabs(reference - 0.12 / sqrt(2)) < 0.001);
    assert(fabs(tone(48000, 48000, 1000, 0.3f, false, flat) / reference - 0.3) < 0.001);
    assert(tone(48000, 48000, 1000, 1, true, flat) == 0);
    for (unsigned i = 0; i < LX_BANDS; i++) {
        float gains[LX_BANDS] = {0};
        gains[i] = i % 2 ? -6 : 6;
        double frequency = LXBandFrequency(i);
        double before = tone(48000, 48000, frequency, 1, false, flat);
        double after = tone(48000, 48000, frequency, 1, false, gains);
        double measured = 20 * log10(after / before);
        assert(fabs(measured - gains[i]) < 0.05);
        assert(fabs(LXResponseDB(frequency, 48000, gains) - measured) < 0.05);
    }
    assert(fabs(tone(44100, 48000, 1000, 1, false, flat) - reference) < 0.001);
    assert(fabs(tone(96000, 44100, 1000, 1, false, flat) - reference) < 0.001);
    float treble[LX_BANDS] = {0, 0, 0, 0, 12};
    assert(!LXBandAvailable(4, 16000) && !LXBandAvailable(4, 24000));
    assert(!LXBandAvailable(3, 8000) && LXBandAvailable(4, 32000));
    assert(LXResponseDB(7200, 16000, treble) == 0);
    assert(tone(16000, 16000, 7200, 1, false, treble) == tone(16000, 16000, 7200, 1, false, flat));
    // A band just below Nyquist must peak at its labeled frequency.
    assert(fabs(LXResponseDB(12000, 25000, treble) - 12) < 1e-6);
    double highBand = tone(25000, 25000, 12000, 1, false, treble);
    double highFlat = tone(25000, 25000, 12000, 1, false, flat);
    assert(fabs(20 * log10(highBand / highFlat) - 12) < 0.05);
    // A plotted point includes the contribution of every available stage at that frequency.
    double points[] = {30, 80, 315, 1000, 4000, 7900}, curve[6];
    float combined[LX_BANDS] = {4, -6, 3, 7, -9};
    LXResponseCurveDB(16000, combined, points, curve, 6);
    for (unsigned i = 0; i < 6; i++) {
        double expected = 0;
        for (unsigned j = 0; j < LX_BANDS; j++) {
            float solo[LX_BANDS] = {0};
            solo[j] = combined[j];
            expected += LXResponseDB(points[i], 16000, solo);
        }
        assert(fabs(curve[i] - expected) < 1e-8);
    }
    testLiveEQ();
    assert(!LXSignalCreate(0, 48000));
    LXSignal *s = LXSignalCreate(48000, 48000);
    float input[512], mono[512];
    for (unsigned i = 0; i < 512; i++) input[i] = 0.5f;
    for (unsigned i = 0; i < 100; i++) LXSignalPush(s, input, input, 1, 512);
    LXSignalRender(s, mono, 1, 512);
    assert(mono[511] > 0.4f);
    for (unsigned i = 0; i < 100; i++) LXSignalRender(s, mono, 1, 512);
    assert(mono[511] == 0 && LXSignalPeak(s) == 0);
    for (unsigned i = 0; i < 5; i++) LXSignalPush(s, input, input, 1, 512);
    LXSignalRender(s, mono, 1, 512);
    assert(mono[511] > 0.4f);
    LXSignalDestroy(s);
    puts("Passed gain, mute, five EQ bands, response curve, live EQ transitions, low-rate outputs, stereo, mono, rate conversion and buffer recovery.");
}
