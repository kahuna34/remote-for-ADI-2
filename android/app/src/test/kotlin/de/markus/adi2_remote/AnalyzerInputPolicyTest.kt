package de.markus.adi2_remote

import kotlin.math.*

/** JVM regression tests: never deliver another device's PCM, preserve PCM units. */
fun main() {
    check(AnalyzerInputPolicy.accepts(17, 17, true, "RME ADI-2 DAC"))
    check(!AnalyzerInputPolicy.accepts(17, null, true, "RME ADI-2 DAC"))
    check(!AnalyzerInputPolicy.accepts(17, 22, true, "RME ADI-2 DAC"))
    check(!AnalyzerInputPolicy.accepts(17, 17, false, "ADI-2 Phone microphone"))
    check(!AnalyzerInputPolicy.accepts(17, 17, true, "Other USB microphone"))
    check(!AnalyzerInputPolicy.accepts(17, 17, true, "RME Fireface"))
    check(AnalyzerInputPolicy.pcm16(Short.MIN_VALUE) == -1f)
    check(AnalyzerInputPolicy.pcm16(Short.MAX_VALUE) == 32767f / 32768f)
    check(AnalyzerInputPolicy.pcm16(0) == 0f)
    check(abs(20 * log10(AnalyzerInputPolicy.pcm16(16384).toDouble()) + 6.020599913) < 1e-8)
    check(!AnalyzerInputPolicy.validPcm(floatArrayOf(0f, Float.NaN), 2))
    check(!AnalyzerInputPolicy.validPcm(floatArrayOf(0f, Float.POSITIVE_INFINITY), 2))
    check(!AnalyzerInputPolicy.validPcm(floatArrayOf(12345f, 0f), 2))
    check(!AnalyzerInputPolicy.validPcm(floatArrayOf(0f, 0f), 1))
    check(AnalyzerInputPolicy.validPcm(floatArrayOf(-1f, 1f), 2))

    for (rate in listOf(44100, 48000, 96000, 192000)) {
        val gate = AnalyzerSelfTestQuiet(rate)
        val silent = FloatArray(rate)
        check(gate.addCaptureBlock(silent, silent.size, 0, 0, false))
        check(gate.quiet)
        // Even silent input cannot satisfy a quiet check during a test tone.
        check(!gate.addCaptureBlock(silent, silent.size, 1, 0, true))
        check(!gate.quiet)
        check(!gate.addCaptureBlock(silent, silent.size, 499_999_999, 500_000_000, false))
        check(!gate.quiet)
        check(gate.addCaptureBlock(silent, silent.size, 500_000_000, 500_000_000, false))
        check(gate.quiet)
        val measured = AnalyzerSelfTestQuiet(rate)
        repeat(rate / 2) { i ->
            measured.add(.5 * sin(2 * PI * 50 * i / rate), .1 * sin(2 * PI * 1000 * i / rate))
        }
        val channels = measured.details()["channels"] as List<*>
        val left = channels[0] as Map<*, *>
        val right = channels[1] as Map<*, *>
        check(abs((left["peakDbfs"] as Double) + 6.0206) < .02)
        check(abs((right["rmsDbfs"] as Double) + 23.0103) < .02)
        check(abs((left["dominantHz"] as Double) - 50) < 15)
        check(abs((right["dominantHz"] as Double) - 1000) < 25)
        check(left["shape"] == "Brummen um 50 Hz")
        check(right["shape"] == "schmalbandig / Ton")
        check("spectrumDbfs" !in left) // Only a scalar spectral summary crosses the channel.
    }
    println("Analyzer input route, PCM16/float, tone exclusion, drain timing and L/R spectrum PASSED")
}
