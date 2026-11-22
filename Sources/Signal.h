#pragma once
#include <stdint.h>
#include <stdbool.h>

#define LX_BANDS 5
typedef struct LXSignal LXSignal;

double LXBandFrequency(unsigned band);
bool LXBandAvailable(unsigned band, double sampleRate);
double LXResponseDB(double frequency, double sampleRate, const float gains[LX_BANDS]);
void LXResponseCurveDB(double sampleRate, const float gains[LX_BANDS], const double *frequencies,
                       double *decibels, unsigned count);
LXSignal *LXSignalCreate(double sourceRate, double outputRate);
void LXSignalDestroy(LXSignal *signal);
void LXSignalSet(LXSignal *signal, float volume, bool muted, const float gains[LX_BANDS]);
// One producer and one consumer. Strides are in samples. No allocations in either callback.
void LXSignalPush(LXSignal *signal, const float *left, const float *right,
                  unsigned stride, unsigned frames);
void LXSignalRender(LXSignal *signal, float *output, unsigned channels, unsigned frames);
float LXSignalPeak(LXSignal *signal);
