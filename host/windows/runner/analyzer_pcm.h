#ifndef RUNNER_ANALYZER_PCM_H_
#define RUNNER_ANALYZER_PCM_H_

#include <cmath>
#include <cstdint>
#include <cstring>

namespace adi2 {
// Call only after validating Float32 or signed PCM16/24/32 containers. Valid
// bits in WAVEFORMATEXTENSIBLE are left-aligned, so container scaling applies.
inline double AnalyzerPcmSample(const uint8_t* p, int bits, bool floating) {
  if (floating) {
    float v; std::memcpy(&v, p, sizeof(v));
    return std::isfinite(v) ? static_cast<double>(v) : 0;
  }
  if (bits == 16) { int16_t v; std::memcpy(&v, p, 2); return v / 32768.0; }
  if (bits == 24) {
    int32_t v = p[0] | (static_cast<int32_t>(p[1]) << 8) |
        (static_cast<int32_t>(p[2]) << 16);
    if (v & 0x800000) v |= ~0xffffff;
    return v / 8388608.0;
  }
  int32_t v; std::memcpy(&v, p, 4); return v / 2147483648.0;
}
}  // namespace adi2
#endif
