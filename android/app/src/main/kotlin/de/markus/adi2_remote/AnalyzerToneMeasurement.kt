package de.markus.adi2_remote

import kotlin.math.*

/** The actual self-test measurement, also executable on a plain JVM. No FFT or UI ballistics. */
internal class AnalyzerToneMeasurement(val rate: Int, val resolution: Int, val index: Int) {
    val frequency = AnalyzerFilterBank.centre(index, resolution)
    val settling = maxOf(0.8, (if (frequency < 40) 40 else 20) / frequency,
        6 / (frequency * (10.0.pow(0.3 / resolution) - 1)))
    val window = max(0.4, (if (frequency < 40) 40 else 20) / frequency)
    private val hop = (rate / 60.0).roundToInt()
    private val settleHops = ceil(settling * rate / hop).toInt()
    // Even number of hops gives equally long stability halves, >=10 periods each.
    private val windowHops = 2 * ceil(window * rate / hop / 2).toInt()
    val duration = (settleHops + windowHops) * hop.toDouble() / rate
    private val bank = AnalyzerFilterBank(rate, resolution)
    val trace = mutableListOf<Map<String, Any>>()
    private val sums = Array(2) { DoubleArray(bank.count) }
    private val squares = Array(2) { DoubleArray(2) }
    private val peaks = DoubleArray(2)
    private var bandMinimum = Double.POSITIVE_INFINITY
    private var bandMaximum = Double.NEGATIVE_INFINITY
    // A digital dropout is not a sine zero crossing: five ms of near-zero PCM
    // after settling is latched even if both window halves lose equal energy.
    private var silentSamples = 0
    private var dropout = false
    private var samples = 0
    var clipped = false
        private set
    var complete = false
        private set
    val elapsed get() = samples.toDouble() / rate

    fun add(pcm: FloatArray, length: Int) {
        require(length in 0..pcm.size && length % 2 == 0)
        for (i in 0 until length step 2) {
            if (complete) break
            val l = pcm[i].toDouble(); val r = pcm[i + 1].toDouble()
            bank.process(l, r)
            val frame = samples / hop
            if (frame >= settleHops) {
                silentSamples = if (max(abs(l), abs(r)) <= 1e-9) silentSamples + 1 else 0
                dropout = dropout || silentSamples >= ceil(rate * .005).toInt()
                val half = min(1, (frame - settleHops) / (windowHops / 2))
                for (ch in 0..1) {
                    val v = if (ch == 0) l else r
                    squares[half][ch] += v * v
                    peaks[ch] = max(peaks[ch], abs(v))
                    clipped = clipped || abs(v) >= 0.999969
                }
            }
            samples++
            if (samples % hop != 0) continue
            val levels = bank.levels()
            trace.add(mapOf("seconds" to elapsed, "db" to levels[index]))
            if (frame >= settleHops) {
                val half = min(1, (frame - settleHops) / (windowHops / 2))
                for (b in levels.indices) sums[half][b] += 10.0.pow(levels[b] / 10)
                bandMinimum = min(bandMinimum, levels[index])
                bandMaximum = max(bandMaximum, levels[index])
            }
            complete = samples / hop >= settleHops + windowHops
        }
    }

    fun result(): Map<String, Any> {
        check(complete)
        val levels = DoubleArray(bank.count) { 10 * log10((sums[0][it] + sums[1][it]) / windowHops) }
        val broadband = DoubleArray(2) { ch ->
            analyzerDb(sqrt((squares[0][ch] + squares[1][ch]) / (windowHops * hop)))
        }
        val bandDrift = abs(10 * log10(sums[1][index] / sums[0][index]))
        val active = if (broadband[0] >= broadband[1]) 0 else 1
        val rmsDrift = abs(10 * log10(squares[1][active] / squares[0][active]))
        val span = bandMaximum - bandMinimum
        val reasons = mutableListOf<String>()
        if (!bandDrift.isFinite() || !rmsDrift.isFinite() || !span.isFinite()) reasons += "nonFiniteLevel"
        if (bandDrift >= .5) reasons += "bandDrift"
        if (rmsDrift >= .5) reasons += "broadbandDrift"
        if (span >= .5) reasons += "bandSpan"
        if (clipped) reasons += "clipping"
        if (dropout) reasons += "dropout"
        return mapOf("levels" to levels, "trace" to trace,
            "broadbandRmsDbfs" to broadband, "broadbandPeakDbfs" to peaks.map(::analyzerDb),
            "bandMinusBroadbandSineDb" to (levels[index] - broadband.max() - 10 * log10(2.0)),
            "bandDriftDb" to bandDrift, "broadbandDriftDb" to rmsDrift,
            "bandSpanDb" to span,
            "invalidReason" to reasons.joinToString(", "), "dropout" to dropout,
            "stabilityLimitDb" to .5,
            "stable" to reasons.isEmpty(),
            "clipped" to clipped, "settlingSeconds" to (settleHops * hop.toDouble() / rate),
            "stableWindowSeconds" to (windowHops * hop.toDouble() / rate),
            "measurementSeconds" to elapsed)
    }
}

/** Shared playback definition: FLOAT normalized to 1.0, PCM16 quantized from it. */
internal class AnalyzerTestTone(private val rate: Int, private val frequency: Double) {
    private var frame = 0L
    fun next(): Float = (0.1 * sin(2 * PI * frequency * frame++ / rate)).toFloat()
}
