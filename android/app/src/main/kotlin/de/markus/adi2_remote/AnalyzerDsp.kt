package de.markus.adi2_remote

import kotlin.math.*

/** Independent 60 Hz filter-bank/meter frames and 75%-overlapped multiresolution FFTs. */
internal class AnalyzerDsp(private val rate: Int, bandsPerOctave: Int = 3) {
    private val fastSize = generateSequence(2048) { it * 2 }.first { rate.toDouble() / it <= 48000.0 / 2048 }
    private val fast = AnalyzerFft(rate, fastSize)
    private val bass = AnalyzerFft(rate, fastSize * 4)
    private var bank = AnalyzerFilterBank(rate, bandsPerOctave)
    var resolution = bandsPerOctave
    private val meters = AnalyzerMeters(rate)
    private val hop = (rate / 60.0).roundToInt()
    private var count = 0
    private val peaks = DoubleArray(2)
    private val squares = DoubleArray(2)
    private val clipped = BooleanArray(2)
    fun add(block: FloatArray, length: Int, emit: (Map<String, Any>) -> Unit) {
        require(length in 0..block.size && length % 2 == 0)
        if (resolution != bank.bandsPerOctave) bank = AnalyzerFilterBank(rate, resolution)
        var i = 0
        while (i < length) {
            val l = block[i++].toDouble(); val r = block[i++].toDouble()
            bank.process(l, r); meters.process(l, r)
            fast.push(l, r); bass.push(l, r)
            for (ch in 0..1) {
                val v = if (ch == 0) l else r
                peaks[ch] = max(peaks[ch], abs(v))
                squares[ch] += v * v
                clipped[ch] = clipped[ch] || abs(v) >= 0.999969
            }
            if (++count == hop) {
                emit(mapOf("sampleRate" to rate, "seconds" to hop.toDouble() / rate,
                    "spectrum" to if (fast.spectrum.isEmpty()) DoubleArray(fastSize / 2 + 1) else fast.spectrum, "bassSpectrum" to bass.spectrum.copyOfRange(0,
                        min(bass.spectrum.size, ceil(360.0 * bass.size / rate).toInt() + 2)),
                    "bassBinHz" to rate.toDouble() / bass.size,
                    "bandLevels" to bank.levels(), "bandsPerOctave" to bank.bandsPerOctave,
                    "peak" to DoubleArray(2) { analyzerDb(peaks[it]) },
                    "rms" to DoubleArray(2) { analyzerDb(sqrt(squares[it] / hop)) },
                    "meterPeak" to meters.peak(), "meterRms" to meters.rms(),
                    "clipped" to clipped.toList()))
                count = 0; peaks.fill(0.0); squares.fill(0.0); clipped.fill(false)
            }
        }
    }
}

internal class AnalyzerFft(private val rate: Int, val size: Int) {
    var spectrum = doubleArrayOf()
        private set
    private val samples = FloatArray(size * 2)
    private var count = 0
    private val cosines = DoubleArray(size / 2) { cos(-2 * PI * it / size) }
    private val sines = DoubleArray(size / 2) { sin(-2 * PI * it / size) }
    private val window = DoubleArray(size) { 0.5 - 0.5 * cos(2 * PI * it / size) }

    fun push(left: Double, right: Double) {
        samples[count++] = left.toFloat(); samples[count++] = right.toFloat()
        if (count == samples.size) {
            spectrum = analyze()
            val hop = size / 2 // stereo samples for size/4 frames
            samples.copyInto(samples, 0, hop, samples.size)
            count -= hop
        }
    }

    private fun analyze(): DoubleArray {
        val power = DoubleArray(size / 2 + 1)
        for (ch in 0..1) {
            val re = DoubleArray(size)
            val im = DoubleArray(size)
            for (i in 0 until size) {
                val v = samples[i * 2 + ch].toDouble()
                re[i] = v * window[i]
            }
            var j = 0
            for (i in 1 until size) {
                var bit = size shr 1
                while ((j and bit) != 0) { j = j xor bit; bit = bit shr 1 }
                j = j xor bit
                if (i < j) { val v = re[i]; re[i] = re[j]; re[j] = v }
            }
            var len = 2
            while (len <= size) {
                val stride = size / len
                for (start in 0 until size step len) {
                    for (k in 0 until len / 2) {
                        val a = start + k
                        val b = a + len / 2
                        val c = cosines[k * stride]; val s = sines[k * stride]
                        val r = re[b] * c - im[b] * s
                        val v = re[b] * s + im[b] * c
                        re[b] = re[a] - r; im[b] = im[a] - v
                        re[a] += r; im[a] += v
                    }
                }
                len = len shl 1
            }
            for (k in power.indices) {
                val scale = if (k == 0 || k == size / 2) 2.0 / size else 4.0 / size
                power[k] = max(power[k], (re[k] * re[k] + im[k] * im[k]) * scale * scale)
            }
        }
        return DoubleArray(power.size) { sqrt(power[it]) }
    }
}
