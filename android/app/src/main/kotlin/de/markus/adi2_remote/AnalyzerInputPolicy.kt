package de.markus.adi2_remote

/** Pure policy shared by negotiation and every delivered PCM block. */
internal object AnalyzerInputPolicy {
    fun isAdi2(usb: Boolean, name: String) = usb &&
        (name.contains("ADI-2", true) || name.contains("ADI 2", true))
    fun accepts(expectedId: Int, routedId: Int?, usb: Boolean, name: String) =
        routedId == expectedId && isAdi2(usb, name)
    fun pcm16(value: Short) = value / 32768f
    fun validPcm(samples: FloatArray, length: Int) = length > 0 && length <= samples.size &&
        length % 2 == 0 && (0 until length).all { samples[it].isFinite() && kotlin.math.abs(samples[it]) <= 1.0001f }
}
