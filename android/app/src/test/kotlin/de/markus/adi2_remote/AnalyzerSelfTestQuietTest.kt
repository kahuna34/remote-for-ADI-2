package de.markus.adi2_remote

import kotlin.math.*

/** Runs on the JVM against the actual native self-test gate. */
fun main() {
    for (rate in listOf(44100, 48000, 96000, 192000)) {
        val size = (rate + 1) / 2
        fun constant(db: Double, rightOnly: Boolean = false): AnalyzerSelfTestQuiet {
            val gate = AnalyzerSelfTestQuiet(rate)
            val value = 10.0.pow(db / 20)
            repeat(size) { gate.add(if (rightOnly) 0.0 else value, value) }
            return gate
        }
        check(constant(-80.0).quiet)
        check(!constant(-65.0).quiet)
        check(!constant(-70.0).quiet)
        check(constant(-70.1, true).quiet)
        val gate = AnalyzerSelfTestQuiet(rate)
        repeat(size - 1) { gate.add(0.0, 0.0) }
        check(!gate.quiet) // At least 500 ms, even at the highest sample rate.
        gate.add(0.01, 0.0)
        check(gate.quiet) // An isolated click is below the 99.9th percentile.
        check(gate.peakDbfs == -160.0)
        check(gate.details()["windowMs"] == 500.0)
        val clicks = AnalyzerSelfTestQuiet(rate)
        repeat(size) { clicks.add(if (it < floor(size * .001).toInt()) .001 else 0.0, 0.0) }
        check(clicks.quiet) // Entire allowed top 0.1% is ignored by nearest rank.
        val boundary = AnalyzerSelfTestQuiet(rate)
        repeat(size) { boundary.add(0.0, if (it < ceil(size * .002).toInt()) .001 else 0.0) }
        check(!boundary.quiet) // RMS passes, sustained peak is exactly -60 dBFS.
        check(abs(boundary.peakDbfs + 60) < 1e-9)
        check(boundary.rmsDbfs < -70)
        repeat(size) { gate.add(0.0, 0.0) }
        check(gate.quiet)
        repeat(ceil(size * .002).toInt()) { gate.add(0.0, .001) }
        check(!gate.quiet) // Sustained noise also invalidates a partial window.
        val measured = constant(-42.0, true)
        val details = measured.details()
        check(abs((details.getValue("peakDbfs") as Double) + 42) < 1e-9)
        check(abs((details.getValue("rmsDbfs") as Double) + 42) < 1e-9)
        val channels = details["channels"] as List<*>
        check((channels[1] as Map<*, *>)["peakDbfs"] == details["peakDbfs"])
        gate.add(Double.NaN, 0.0)
        check(!gate.quiet)
        val bad = AnalyzerSelfTestQuiet(rate)
        repeat(size) { bad.add(if (it == 0) Double.NaN else 0.0, 0.0) }
        check(!bad.quiet)

        // Real block path: no first tone may start until the initial check ends.
        val ordered = AnalyzerSelfTestQuiet(rate)
        val silent = FloatArray(size * 2)
        check(!ordered.readyForTone(1_000_000_000L))
        ordered.addCaptureBlock(silent, silent.size, 1_000_000_000L, 0L, false)
        check(ordered.windowStartNs == 1_000_000_000L)
        check(ordered.windowEndNs == 1_500_000_000L)
        check(!ordered.readyForTone(ordered.windowEndNs))
        check(ordered.readyForTone(ordered.windowEndNs + 1))
        check(!ordered.readyForTone(ordered.windowEndNs + 500_000_000L))

        // Long measured loopback latency plus decaying residual audio.
        val stopped = 2_000_000_000L
        check(AnalyzerSelfTestQuiet.drainNs(0) == 500_000_000L)
        val after = stopped + AnalyzerSelfTestQuiet.drainNs(950_000_000L)
        check(after == 3_250_000_000L)
        check(!ordered.addCaptureBlock(silent, silent.size, stopped, after, true))
        check(!ordered.readyForTone(stopped + 1))
        check(!ordered.addCaptureBlock(silent, silent.size, after - 1, after, false))
        // A tail beyond the latency deadline must still block the next tone.
        val tail = FloatArray(size * 2) { (.01 * exp(-3.0 * it / (size * 2))).toFloat() }
        ordered.addCaptureBlock(tail, tail.size, after, after, false)
        check(!ordered.readyForTone(after + 500_000_001L))
        val half = FloatArray(size) // Only 250 ms of subsequent silence.
        ordered.addCaptureBlock(half, half.size, after + 500_000_000L, after, false)
        check(!ordered.quiet)
        ordered.addCaptureBlock(half, half.size, after + 750_000_000L, after, false)
        check(ordered.readyForTone(after + 1_000_000_001L))
        check(ordered.windowStartNs >= after)
        check(ordered.windowEndNs < after + 1_000_000_001L)
    }
    println("Analyzer self-test 500 ms, percentile, strict thresholds, pre-tone order and latency/tail drain PASSED")
}
