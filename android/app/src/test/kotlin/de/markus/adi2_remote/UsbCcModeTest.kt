package de.markus.adi2_remote

// Standalone JVM unit tests, requiring only Kotlin's standard library.
// Compile with UsbCcMode.kt, then run de.markus.adi2_remote.UsbCcModeTestKt.
fun main() {
    UsbCcModeTest().apply {
        recordingChannelCounts()
        ignoresPlaybackFeedbackAndMidi()
        alternateSettingsAreNotSummed()
        malformedAndUnsupportedDescriptorsAreUnknown()
    }
    println("USB CC mode: 4 test groups passed")
}

class UsbCcModeTest {
    private fun assertEquals(expected: String, actual: String) {
        check(expected == actual) { "Expected $expected, got $actual" }
    }
    private fun bytes(vararg values: Int) = values.map { it.toByte() }.toByteArray()

    private fun stream(channels: Int, endpoint: Int = 0x81, attributes: Int = 5,
                       number: Int = 1, alternate: Int = 1, protocol: Int = 0x20) =
        bytes(9, 4, number, alternate, 1, 1, 2, protocol, 0) +
        // AS_GENERAL: bTerminalLink=3, PCM, then the channel cluster.
        bytes(16, 0x24, 1, 3, 0, 1, 1, 0, 0, 0, channels, 0, 0, 0, 0, 0) +
        bytes(7, 5, endpoint, attributes, 0, 4, 1)

    fun recordingChannelCounts() {
        assertEquals("stereo", parseUsbCcMode(stream(2)))
        assertEquals("multi", parseUsbCcMode(stream(6)))
        assertEquals("multi", parseUsbCcMode(stream(8)))
        assertEquals("unknown", parseUsbCcMode(stream(4)))
        assertEquals("unknown", parseUsbCcMode(stream(0)))
    }

    fun ignoresPlaybackFeedbackAndMidi() {
        assertEquals("unknown", parseUsbCcMode(stream(8, endpoint = 1)))
        assertEquals("unknown", parseUsbCcMode(stream(8, attributes = 0x11)))
        assertEquals("multi", parseUsbCcMode(stream(6, attributes = 0x25)))
        assertEquals("stereo", parseUsbCcMode(stream(8, endpoint = 1) + stream(2)))
        val midi = bytes(9, 4, 3, 0, 1, 1, 3, 0, 0) +
            bytes(7, 0x24, 1, 0, 1, 6, 0) + bytes(7, 5, 0x83, 2, 64, 0, 0)
        assertEquals("stereo", parseUsbCcMode(stream(2) + midi))
        assertEquals("unknown", parseUsbCcMode(stream(6, protocol = 0)))
    }

    fun alternateSettingsAreNotSummed() {
        assertEquals("stereo", parseUsbCcMode(
            stream(2) + stream(2, alternate = 2) + stream(2, alternate = 3)))
        assertEquals("multi", parseUsbCcMode(stream(6) + stream(2, alternate = 2)))
        assertEquals("multi", parseUsbCcMode(
            stream(2) + stream(2, number = 2) + stream(2, number = 3)))
        assertEquals("unknown", parseUsbCcMode(stream(2) + stream(0, number = 2)))
    }

    fun malformedAndUnsupportedDescriptorsAreUnknown() {
        for (raw in listOf(byteArrayOf(), bytes(0, 4), bytes(1, 4), bytes(9),
            bytes(9, 4, 1), stream(6).dropLast(1).toByteArray(), stream(6) + bytes(0, 0),
            bytes(9, 4, 1, 1, 1, 1, 2, 0x20, 0) + bytes(3, 0x24, 1))) {
            assertEquals("unknown", parseUsbCcMode(raw))
        }
        val configuration = bytes(9, 2, 9, 0, 0, 1, 0, 0x80, 50)
        assertEquals("unknown", parseUsbCcMode(configuration + stream(2) + configuration + stream(6)))
    }
}
