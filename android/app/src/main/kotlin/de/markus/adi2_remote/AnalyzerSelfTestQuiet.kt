package de.markus.adi2_remote

import kotlin.math.*

/** At least 500 ms stereo windows; nearest-rank 99.9th percentile of absolute PCM. */
internal class AnalyzerSelfTestQuiet(private val rate: Int) {
    companion object {
        fun drainNs(measuredLatencyNs: Long) = max(500_000_000L, measuredLatencyNs + 300_000_000L)
    }
    fun readyForTone(commandNs: Long) = quiet && windowEndNs > 0L &&
        commandNs > windowEndNs && commandNs - windowEndNs < 500_000_000L

    private val window = Array(2) { DoubleArray((rate + 1) / 2) }
    private var previous = Array(2) { DoubleArray(0) }
    private var frames = 0
    private var invalid = false
    private val outliers = IntArray(2)
    var windowStartNs = 0L
        private set
    var windowEndNs = 0L
        private set
    private var leftPower = 0.0
    private var rightPower = 0.0
    var quiet = false
        private set
    var peakDbfs = -160.0
        private set
    var rmsDbfs = -160.0
        private set

    /** A whole block must follow the output/USB drain interval, with no test tone. */
    fun addCaptureBlock(pcm: FloatArray, length: Int, blockStartNs: Long,
                        quietAfterNs: Long, testPlaybackActive: Boolean): Boolean {
        if (testPlaybackActive || blockStartNs < quietAfterNs) {
            quiet = false
            frames = 0; invalid = false; outliers.fill(0); leftPower = 0.0; rightPower = 0.0
            peakDbfs = -160.0; rmsDbfs = -160.0
            previous = Array(2) { DoubleArray(0) }
            return false
        }
        require(length in 0..pcm.size && length % 2 == 0)
        for (i in 0 until length step 2) {
            add(pcm[i].toDouble(), pcm[i + 1].toDouble())
            if (frames == 0) {
                windowEndNs = blockStartNs + ((i / 2 + 1) * 1e9 / rate).toLong()
                windowStartNs = windowEndNs - (window[0].size * 1e9 / rate).toLong()
            }
        }
        return true
    }

    fun add(left: Double, right: Double) {
        val valid = left.isFinite() && right.isFinite()
        invalid = invalid || !valid
        if (abs(left) >= 0.001) outliers[0]++
        if (abs(right) >= 0.001) outliers[1]++
        leftPower += left * left
        rightPower += right * right
        if (frames < window[0].size) { window[0][frames] = left; window[1][frames] = right }
        frames++
        // Invalidate sustained noise immediately, while allowing isolated clicks.
        val allowedOutliers = window[0].size - ceil(.999 * window[0].size).toInt()
        if (invalid || outliers.any { it > allowedOutliers } ||
            max(leftPower, rightPower) / window[0].size >= 1e-7) quiet = false
        if (frames >= window[0].size) {
            peakDbfs = if (invalid) Double.POSITIVE_INFINITY else
                db(max(percentile(window[0]), percentile(window[1])))
            rmsDbfs = db(sqrt(max(leftPower, rightPower) / frames))
            // Tiny margin avoids accepting a boundary through accumulated roundoff.
            quiet = !invalid && peakDbfs < -60 - 1e-9 && rmsDbfs < -70 - 1e-9
            previous = Array(2) { window[it].copyOf() }
            frames = 0; invalid = false; outliers.fill(0); leftPower = 0.0; rightPower = 0.0
        }
    }

    fun details(): Map<String, Any> {
        // Completed decisions and diagnostics share a window; show partial data if invalidated.
        val data = if (frames > 0 && !quiet) Array(2) { window[it].copyOf(frames) } else previous
        val channels = data.map { samples -> describe(samples) }
        val partial = frames > 0 && !quiet
        val reportedPeak = if (partial) db(max(percentile(data[0]), percentile(data[1]))) else peakDbfs
        val reportedRms = if (partial) db(sqrt(max(leftPower, rightPower) / frames)) else rmsDbfs
        return mapOf("peakDbfs" to reportedPeak, "rmsDbfs" to reportedRms,
            "peakPercentile" to 99.9, "channels" to channels,
            "windowMs" to data[0].size * 1000.0 / rate,
            "interpretation" to "Spektrum ist ein Hinweis; Sprache/Raumgeräusch beweist keine Mikrofonroute")
    }

    private fun percentile(samples: DoubleArray): Double {
        if (samples.isEmpty()) return 0.0
        if (samples.any { !it.isFinite() }) return Double.POSITIVE_INFINITY
        val sorted = DoubleArray(samples.size) { abs(samples[it]) }
        sorted.sort()
        return sorted[ceil(.999 * sorted.size).toInt() - 1]
    }

    private fun describe(samples: DoubleArray): Map<String, Any> {
        if (samples.isEmpty()) return mapOf("shape" to "noch kein vollständiges Fenster")
        if (samples.any { !it.isFinite() }) return mapOf("shape" to "ungültiges PCM")
        val peak = samples.maxOf { abs(it) }
        val power = samples.sumOf { it * it } / samples.size
        val mean = samples.average()
        // Analyze L/R independently, without the production FFT's max(L,R).
        val size = generateSequence(128) { it * 2 }.first { it * 2 > samples.size.coerceAtLeast(128) }
        val fft = AnalyzerFft(rate, size)
        for (i in 0 until min(size, samples.size)) fft.push(samples[i], 0.0)
        val spectrum = fft.spectrum
        val dominant = if (spectrum.isEmpty()) 0 else spectrum.indices.maxBy { spectrum[it] }
        val powers = spectrum.map { it * it }
        val sum = powers.sum()
        val tonal = if (sum > 0) (max(0, dominant - 1)..min(powers.lastIndex, dominant + 1)).sumOf { powers[it] } / sum else 0.0
        val hz = dominant * rate.toDouble() / size
        val shape = when {
            peak < 1e-8 -> "digitale Stille"
            mean * mean > power * .8 -> "Gleichanteil / DC"
            hz in 35.0..70.0 && tonal > .5 -> "Brummen um 50 Hz"
            tonal > .7 -> "schmalbandig / Ton"
            else -> "breitbandig / wechselnd (Raumgeräusch oder Sprache möglich)"
        }
        return mapOf("peakDbfs" to db(percentile(samples)), "maximumDbfs" to db(peak), "rmsDbfs" to db(sqrt(power)), "dc" to mean,
            "dominantHz" to hz, "binHz" to rate.toDouble() / size, "shape" to shape,
            "tonalPowerFraction" to tonal)
    }
    private fun db(amplitude: Double) = 20 * log10(max(amplitude, 1e-8))
}
