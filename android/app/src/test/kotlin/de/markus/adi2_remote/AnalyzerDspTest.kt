package de.markus.adi2_remote

import kotlin.math.*

/** Standalone JVM checks exercise the exact worker DSP without Android mocks. */
fun main() {
    val fft = AnalyzerFft(48000, 2048)
    repeat(2048) { i ->
        val v = sin(2 * PI * 1500 * i / 48000)
        fft.push(v, 0.0)
    }
    check(abs(analyzerDb(fft.spectrum[64])) < 0.001)
    check(abs(fft.spectrum[63] - 0.5) < 0.001)
    val meters = AnalyzerMeters(48000)
    meters.process(1.0, 0.5)
    check(abs(meters.peak()[1] + 6.0206) < 0.001)
    repeat(72000) { meters.process(0.0, 0.0) }
    check(abs(meters.peak()[0] + 20) < 1e-7)
    val rms = AnalyzerMeters(48000)
    repeat(14400) { rms.process(1.0, 0.0) }
    check(abs(rms.rms()[0] - 10 * log10(1 - exp(-1.0))) < 1e-8)
    for (rate in listOf(44100, 48000, 96000, 192000)) {
        for (resolution in listOf(3, 6, 12)) {
            val dsp = AnalyzerDsp(rate, resolution)
            var frames = 0
            var latest: Map<String, Any>? = null
            // Arbitrary stereo capture blocks, including blocks below one hop.
            var offset = 0
            val started = System.nanoTime()
            while (offset < rate) {
                val n = min(347, rate - offset)
                val block = FloatArray(n * 2) {
                    (sin(2 * PI * 1000 * (offset + it / 2) / rate) * if (it % 2 == 0) 1.0 else -0.5).toFloat()
                }
                dsp.add(block, block.size) { frame -> frames++; latest = frame }
                offset += n
            }
            println("HOST_BENCH,$rate,$resolution," + (System.nanoTime() - started) / 1e6)
            check(frames in 59..60) { "$rate $resolution: $frames frames" }
            val f = requireNotNull(latest)
            val bands = f["bandLevels"] as DoubleArray
            check(bands.size == 29 * resolution / 3 + 1)
            check(bands.indices.maxBy { bands[it] } == 16 * resolution / 3)
            check(abs(bands[16 * resolution / 3]) < 0.1)
            check(abs((f["peak"] as DoubleArray)[0]) < 0.02)
            check(abs((f["peak"] as DoubleArray)[1] + 6.0206) < 0.02)
            check((f["clipped"] as List<*>)[1] == false)
            check(abs((f["rms"] as DoubleArray)[0] + 3.0103) < 0.05)
            check(abs((f["meterRms"] as DoubleArray)[0] + 3.0103 - 10 * log10(1 - exp(-1 / 0.3))) < 0.03)
            check((f["bassBinHz"] as Double) < 6)
            dsp.resolution = if (resolution == 12) 3 else 12
            dsp.add(FloatArray(rate / 30 + 2).let { it.copyOf(it.size / 2 * 2) }, rate / 30 / 2 * 2) { next ->
                check((next["bandLevels"] as DoubleArray).size == 29 * dsp.resolution / 3 + 1)
            }
        }
    }
    for (resolution in listOf(3, 6, 12)) {
        for (thirdBand in listOf(4, 10, 16, 25)) {
            val index = thirdBand * resolution / 3
            val hz = AnalyzerFilterBank.centre(index, resolution)
            val dsp = AnalyzerDsp(48000, resolution)
            var reached: Double? = null
            var latest: Map<String, Any>? = null
            repeat(30) { block ->
                val pcm = FloatArray(1600) { sin(2 * PI * hz * (block * 800 + it / 2) / 48000).toFloat() }
                dsp.add(pcm, pcm.size) { f ->
                    latest = f
                    if ((f["bandLevels"] as DoubleArray)[index] >= -3 && reached == null) reached = (block + 1) * 1000.0 / 60
                }
            }
            check(reached != null && reached <= if (thirdBand == 4) 350 else if (thirdBand == 10) 100 else 50)
            println("STEP,$resolution,$hz,$reached")
            // Compared to Dart in tools/analyzer_audit.dart (Float32 input).
            println("PARITY,$resolution,$thirdBand," + (latest!!["bandLevels"] as DoubleArray).joinToString(","))
        }
    }
    println("Analyzer native: calibration, Max-L/R, 75% FFT, 60Hz, 44.1/48/96/192k, all resolutions, meters and steps PASSED")
}
