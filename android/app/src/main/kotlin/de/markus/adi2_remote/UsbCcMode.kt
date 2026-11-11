package de.markus.adi2_remote

/**
 * UAC2 AS_GENERAL contains an audio channel cluster (bNrChannels, offset 10).
 * Only isochronous IN data endpoints carry recording audio. Playback and IN
 * feedback endpoints must not influence the result. Alternate settings describe
 * the same channels, so take their maximum rather than adding them.
 * USB Audio 2.0, sections 4.9.2 and 4.10.1.
 */
internal fun parseUsbCcMode(raw: ByteArray): String {
    fun byte(at: Int) = raw[at].toInt() and 0xff
    val captureChannels = mutableMapOf<Int, Int>()
    var offset = 0
    var interfaceNumber = -1
    var audioStreaming = false
    var channels: Int? = null
    var capture = false
    var incompleteCapture = false
    var configurations = 0

    fun finishInterface() {
        if (audioStreaming && capture && (channels == null || channels == 0)) {
            incompleteCapture = true
        } else if (audioStreaming && capture && channels != null) {
            captureChannels[interfaceNumber] = maxOf(
                captureChannels[interfaceNumber] ?: 0, channels!!)
        }
    }

    while (offset < raw.size) {
        if (offset + 2 > raw.size) return "unknown"
        val length = byte(offset)
        if (length < 2 || offset + length > raw.size) return "unknown"
        when (byte(offset + 1)) {
            2 -> {
                // Multiple configurations do not identify the active CC mode.
                configurations++
                if (length < 9 || configurations > 1) return "unknown"
            }
            4 -> {
                if (length < 9) return "unknown"
                finishInterface()
                interfaceNumber = byte(offset + 2)
                audioStreaming = byte(offset + 5) == 1 &&
                    byte(offset + 6) == 2 && byte(offset + 7) == 0x20
                channels = null
                capture = false
            }
            0x24 -> if (audioStreaming) {
                if (length < 3) return "unknown"
                if (byte(offset + 2) == 1) {
                    if (length < 16) return "unknown"
                    channels = byte(offset + 10)
                }
            }
            5 -> if (audioStreaming) {
                if (length < 7) return "unknown"
                val address = byte(offset + 2)
                val attributes = byte(offset + 3)
                val usage = attributes and 0x30
                if (address and 0x80 != 0 && attributes and 3 == 1 &&
                    (usage == 0 || usage == 0x20)) capture = true
            }
        }
        offset += length
    }
    finishInterface()
    if (incompleteCapture) return "unknown"
    return when (captureChannels.values.sum()) {
        2 -> "stereo"
        in 6..Int.MAX_VALUE -> "multi"
        else -> "unknown"
    }
}
