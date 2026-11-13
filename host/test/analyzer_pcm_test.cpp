#include "../windows/runner/analyzer_pcm.h"
#include <cassert>
#include <limits>
#include <iostream>

int main() {
  using adi2::AnalyzerPcmSample;
  const uint8_t zero[] = {0, 0, 0, 0};
  const uint8_t min16[] = {0, 0x80}, max16[] = {0xff, 0x7f};
  const uint8_t half16[] = {0, 0x40};
  assert(AnalyzerPcmSample(zero, 16, false) == 0);
  assert(AnalyzerPcmSample(min16, 16, false) == -1);
  assert(AnalyzerPcmSample(max16, 16, false) == 32767.0 / 32768);
  assert(AnalyzerPcmSample(half16, 16, false) == 0.5);
  const uint8_t min24[] = {0, 0, 0x80}, max24[] = {0xff, 0xff, 0x7f};
  const uint8_t negHalf24[] = {0, 0, 0xc0};
  assert(AnalyzerPcmSample(zero, 24, false) == 0);
  assert(AnalyzerPcmSample(min24, 24, false) == -1);
  assert(AnalyzerPcmSample(max24, 24, false) == 8388607.0 / 8388608);
  assert(AnalyzerPcmSample(negHalf24, 24, false) == -0.5);
  const uint8_t min32[] = {0, 0, 0, 0x80}, max32[] = {0xff, 0xff, 0xff, 0x7f};
  const uint8_t padded24[] = {0, 0xff, 0xff, 0x7f};
  assert(AnalyzerPcmSample(zero, 32, false) == 0);
  assert(AnalyzerPcmSample(min32, 32, false) == -1);
  assert(AnalyzerPcmSample(max32, 32, false) == 2147483647.0 / 2147483648.0);
  assert(AnalyzerPcmSample(padded24, 32, false) == 8388607.0 / 8388608);
  for (float value : {0.0f, 0.5f, -1.0f, 1.25f}) {
    assert(AnalyzerPcmSample(reinterpret_cast<const uint8_t*>(&value), 32, true) == value);
  }
  const float nan = std::numeric_limits<float>::quiet_NaN();
  assert(AnalyzerPcmSample(reinterpret_cast<const uint8_t*>(&nan), 32, true) == 0);
  // Deliberately unaligned containers, as can occur inside interleaved frames.
  const uint8_t stereo16[] = {0xaa, 0, 0x40, 0, 0xc0};
  assert(AnalyzerPcmSample(stereo16 + 1, 16, false) == 0.5);
  assert(AnalyzerPcmSample(stereo16 + 3, 16, false) == -0.5);
  std::cout << "PCM16/24/32, padded PCM24, Float32 and unaligned stereo: OK\n";
}
