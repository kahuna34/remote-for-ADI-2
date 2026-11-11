package de.markus.adi2_remote

import kotlin.math.*

fun main() {
    fun measure(rate: Int, resolution: Int, index: Int, pcm16: Boolean = false,
                gain: (Double) -> Double = { 1.0 }): Map<String, Any> {
        val meter = AnalyzerToneMeasurement(rate, resolution, index)
        val generator = AnalyzerTestTone(rate, meter.frequency)
        var frame = 0
        while (!meter.complete) {
            // Non-hop-aligned blocks, right-only (never sum or average channels).
            val block = FloatArray(347 * 2)
            for (i in block.indices step 2) {
                val v = generator.next() * gain(frame++.toDouble() / rate)
                block[i + 1] = if (pcm16) (v * 32768).roundToInt().coerceIn(-32768, 32767) / 32768f else v.toFloat()
            }
            meter.add(block, block.size)
        }
        return meter.result()
    }
    println("EVAL_HEADER,resolution,index,centreDb,lowerDb,upperDb,rmsDb,bandDriftDb,stable")
    for (resolution in listOf(3, 6, 12)) for (index in 0 until (29 * resolution / 3 + 1)) {
        val result = measure(48000, resolution, index)
        val levels = result["levels"] as DoubleArray
        val rms = (result["broadbandRmsDbfs"] as DoubleArray)[1]
        check(abs(levels[index] + 20) <= 0.05) { "$resolution/$index: ${levels[index]}" }
        for (neighbour in listOf(index - 1, index + 1).filter { it in levels.indices })
            check(levels[index] - levels[neighbour] >= 9) { "$resolution/$index -> $neighbour" }
        check(abs(rms + 23.01029995664) < 0.05) { "RMS $resolution/$index: $rms" }
        check(result["stable"] == true) { "$resolution/$index: $result" }
        check((result["broadbandRmsDbfs"] as DoubleArray)[0] == -120.0)
        @Suppress("UNCHECKED_CAST")
        val trace = result["trace"] as List<Map<String, Any>>
        val crossing = trace.indices.firstOrNull { n ->
            n + 3 < trace.size && (n..n+3).all { (trace[it]["db"] as Double) >= levels[index] - 3 }
        }
        check(crossing != null)
        val responseMs = (trace[crossing]["seconds"] as Double) * 1000
        check(responseMs < (result["settlingSeconds"] as Double) * 1000)
        println("RESPONSE,$resolution,$index,$responseMs")
        println("EVAL,$resolution,$index,${levels[index]},${if(index > 0) levels[index-1] else ""},${if(index+1 < levels.size) levels[index+1] else ""},$rms,${result["bandDriftDb"]},${result["stable"]}")
    }
    // Scaling/format/rate checks include the hardware's unusual 70.8 Hz and HF dip.
    for (rate in listOf(44100, 48000, 96000, 192000)) for (index in listOf(0, 9, 32, 48, 50, 56, 58)) {
        val result = measure(rate, 6, index, pcm16 = true)
        check(abs((result["levels"] as DoubleArray)[index] + 20) < .05)
        check(abs((result["broadbandRmsDbfs"] as DoubleArray)[1] + 23.0103) < .05)
        check(result["stable"] == true)
    }
    val settling = AnalyzerToneMeasurement(48000, 3, 16).settling
    val changed = measure(48000, 3, 16) { if (it < settling + .2) 1.0 else .5 }
    check(changed["stable"] == false)
    val modulated = measure(48000, 3, 16) { if ((it * 20).toInt() % 2 == 0) 1.0 else .5 }
    check(modulated["stable"] == false)
    // Modest hardware gain ripple used to fail the 0.25 dB full-span gate.
    val ripple = measure(48000, 3, 16) { 10.0.pow(.2 * sin(2 * PI * 5 * it) / 20) }
    check(ripple["stable"] == true) { "0.4 dB ripple rejected: $ripple" }
    check((ripple["bandSpanDb"] as Double) > .25)
    val excessiveRipple = measure(48000, 3, 16) { 10.0.pow(.4 * sin(2 * PI * 5 * it) / 20) }
    check(excessiveRipple["stable"] == false)
    check((excessiveRipple["invalidReason"] as String).contains("bandSpan"))
    val clipped = measure(48000, 3, 16) { 11.0 }
    check(clipped["stable"] == false && clipped["clipped"] == true)
    // Symmetric holes cannot cancel out in the half-window drift calculation.
    val holes = measure(48000, 3, 16) {
        val phase = (it - settling) % .2
        if (phase >= .08 && phase < .09) 0.0 else 1.0
    }
    check(holes["stable"] == false && holes["dropout"] == true)
    check((holes["invalidReason"] as String).contains("dropout"))
    val silence = measure(48000, 3, 16) { 0.0 }
    check(silence["stable"] == false)
    for (resolution in listOf(3, 6, 12)) for (index in 0..(resolution / 3)) {
        val meter = AnalyzerToneMeasurement(48000, resolution, index)
        check(meter.window * meter.frequency >= 40 - 1e-9)
        check(meter.settling * meter.frequency >= 40 - 1e-9)
    }
    val quiet = measure(48000, 3, 16) { .1 }
    check(abs((quiet["levels"] as DoubleArray)[16] + 40) < .01)
    check(abs((quiet["broadbandRmsDbfs"] as DoubleArray)[1] + 43.0103) < .01)
    println("Native self-test: 206 centres/neighbours/RMS; PCM16 at 4 rates; gain changes/modulation/ripple/clipping/dropouts/low-band timing PASSED")
}
