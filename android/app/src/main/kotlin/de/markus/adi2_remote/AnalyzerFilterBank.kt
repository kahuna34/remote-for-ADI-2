package de.markus.adi2_remote

import kotlin.math.*

/** Bilinear bandpass transform of a second-order Butterworth prototype.
 * Base-10 IEC band centres/edges; no instrument-class certification implied.
 * Two real biquads, centre gain unity. Double states retain low-band precision.
 */
internal class AnalyzerBandFilter(centre: Double, ratio: Double, rate: Int) {
    private val a1 = DoubleArray(2)
    private val a2 = DoubleArray(2)
    private val z1 = DoubleArray(4)
    private val z2 = DoubleArray(4)
    private val gain: Double
    init {
        val lo = tan(PI * centre / ratio / rate)
        val hi = tan(PI * min(centre * ratio, rate * 0.499) / rate)
        val middle = tan(PI * centre / rate)
        // Anchor the resonance to the nominal digital centre. Independently
        // prewarped edges have sqrt(lo*hi) != middle near Nyquist. Normalizing
        // that displaced passband at centre amplified its upper neighbour.
        // Choose the narrower bandwidth so neither nominal edge is exceeded.
        val bandwidth = min((middle * middle - lo * lo) / lo,
            (hi * hi - middle * middle) / hi)
        val real = -bandwidth / sqrt(2.0)
        val imaginary = -real
        val dr = real * real - imaginary * imaginary - 4 * middle * middle
        val di = 2 * real * imaginary
        val magnitude = hypot(dr, di)
        val sr = sqrt(max(0.0, (magnitude + dr) / 2))
        val si = -sqrt(max(0.0, (magnitude - dr) / 2))
        for (section in 0..1) {
            val sign = if (section == 0) -1 else 1
            val pr = (real + sign * sr) / 2
            val pi = (imaginary + sign * si) / 2
            val denominator = (1 - pr).pow(2) + pi * pi
            val zr = (1 - pr * pr - pi * pi) / denominator
            val zi = 2 * pi / denominator
            a1[section] = -2 * zr
            a2[section] = zr * zr + zi * zi
        }
        val w = 2 * PI * centre / rate
        var response = 1.0
        for (section in 0..1) {
            val re = 1 + a1[section] * cos(w) + a2[section] * cos(2 * w)
            val im = -a1[section] * sin(w) - a2[section] * sin(2 * w)
            response *= 2 * abs(sin(w)) / hypot(re, im)
        }
        gain = 1 / response
    }
    fun process(input: Double, channel: Int): Double {
        var value = input
        for (section in 0..1) {
            val state = section * 2 + channel
            val output = value + z1[state]
            z1[state] = -a1[section] * output + z2[state]
            z2[state] = -value - a2[section] * output
            value = output
        }
        return value * gain
    }
}

internal class AnalyzerFilterBank(val rate: Int, val bandsPerOctave: Int) {
    val count = 29 * bandsPerOctave / 3 + 1
    private val filters = Array(count) {
        AnalyzerBandFilter(centre(it, bandsPerOctave), 10.0.pow(0.15 / bandsPerOctave), rate)
    }
    private val left = DoubleArray(count)
    private val right = DoubleArray(count)
    private val quadratureLeft = DoubleArray(count)
    private val quadratureRight = DoubleArray(count)
    private val allpass = DoubleArray(count) {
        val t = tan(PI * centre(it, bandsPerOctave) / rate)
        (t - 1) / (t + 1)
    }
    private val alpha = 1 - exp(-1 / (rate * 0.005))
    fun process(l: Double, r: Double) {
        for (i in 0 until count) {
            val vl = filters[i].process(l, 0)
            val vr = filters[i].process(r, 1)
            // Centre quadrature removes 2*f detector ripple, especially at 25 Hz,
            // while retaining the same short 5 ms integration at every frequency.
            val ql = allpass[i] * vl + quadratureLeft[i]
            val qr = allpass[i] * vr + quadratureRight[i]
            quadratureLeft[i] = vl - allpass[i] * ql
            quadratureRight[i] = vr - allpass[i] * qr
            left[i] += alpha * ((vl * vl + ql * ql) / 2 - left[i])
            right[i] += alpha * ((vr * vr + qr * qr) / 2 - right[i])
        }
    }
    fun levels() = DoubleArray(count) { analyzerDb(sqrt(2 * max(left[it], right[it]))) }
    companion object {
        fun centre(index: Int, bandsPerOctave: Int) = 1000 * 10.0.pow((index * 3.0 / bandsPerOctave - 16) / 10)
    }
}

internal fun analyzerDb(v: Double) = if (v <= 0) -120.0 else (20 * log10(v)).coerceIn(-120.0, 12.0)

internal class AnalyzerMeters(rate: Int) {
    private val alpha = 1 - exp(-1 / (rate * 0.3))
    private val peakFactor = 10.0.pow(-(20 / 1.5) / (20 * rate))
    private val power = DoubleArray(2)
    private val peaks = DoubleArray(2)
    fun process(l: Double, r: Double) {
        for (ch in 0..1) {
            val value = if (ch == 0) l else r
            power[ch] += alpha * (value * value - power[ch])
            peaks[ch] = max(abs(value), peaks[ch] * peakFactor)
        }
    }
    fun peak() = DoubleArray(2) { analyzerDb(peaks[it]) }
    fun rms() = DoubleArray(2) { analyzerDb(sqrt(power[it])) }
}
