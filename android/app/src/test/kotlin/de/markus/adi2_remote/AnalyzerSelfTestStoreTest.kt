package de.markus.adi2_remote

import java.io.File
import java.io.RandomAccessFile
import java.nio.file.Files

/** Run with a small heap: a legacy 165 MB report must never be read into memory. */
fun main() {
    val directory = Files.createTempDirectory("selftest-store").toFile()
    try {
        val store = AnalyzerSelfTestStore(directory)
        fun file(index: Int) = File(directory, "analyzer_selftest_${100 + index}.json")
        fun oversized(file: File, size: Long = 165_753_240) {
            RandomAccessFile(file, "rw").use { it.setLength(size) }
        }
        fun rejected(action: () -> Unit) {
            var rejected = false
            try { action() } catch (_: AnalyzerSelfTestStore.TooLarge) { rejected = true }
            check(rejected)
        }

        // The only report is huge: delete before reading and return a visible notice.
        oversized(file(9))
        check(store.lastResult()!!["notice"]!!.contains("zu groß, verworfen"))
        check(!file(9).exists())
        check(store.lastResult() == null)

        val recovery = File(directory, AnalyzerSelfTestStore.RECOVERY)
        store.save(recovery.name, "{\"values\":{}}")
        repeat(8) { file(it).writeText("{\"index\":$it}") }
        oversized(file(9))
        val abandoned = File(directory, "${file(8).name}.tmp").apply { writeText("unfinished") }
        val unrelated = File(directory, "other.json").apply { writeText("keep") }
        val last = store.lastResult()!!
        check(last["json"] == "{\"index\":7}")
        check(last["notice"]!!.contains("zu groß, verworfen"))
        check(!abandoned.exists() && unrelated.exists())
        check((0..7).count { file(it).exists() } == 5)
        check((0..2).none { file(it).exists() })
        check(recovery.readText() == store.recovery())

        // Bound both characters and UTF-8 bytes; a failed replacement preserves the old file.
        rejected { store.save(file(7).name, "x".repeat(AnalyzerSelfTestStore.WRITE_LIMIT)) }
        rejected { store.save(file(7).name, "€".repeat(400_000)) }
        check(file(7).readText() == last["json"])
        check(store.save(file(8).name, "x".repeat(AnalyzerSelfTestStore.WRITE_LIMIT - 1)).endsWith(file(8).name))
        check((0..8).count { file(it).exists() } == 5)
        check(directory.listFiles()!!.none { it.name.endsWith(".tmp") })

        // Recovery is also bounded, but cannot be silently thrown away.
        oversized(recovery)
        rejected { store.recovery() }
        val recoverySize = recovery.length()
        val recoveryTemporary = File(directory, "${AnalyzerSelfTestStore.RECOVERY}.tmp")
            .apply { writeText("pending journal replacement") }
        // Both read cleanup and saving a report must ignore even oversized recovery files.
        oversized(file(9))
        store.lastResult()
        store.save(file(10).name, "{}")
        check(recovery.exists() && recovery.length() == recoverySize)
        check(recoveryTemporary.readText() == "pending journal replacement")
        rejected { store.save(recovery.name, "x".repeat(AnalyzerSelfTestStore.RECOVERY_LIMIT)) }
        check(recovery.length() == recoverySize)
        rejected { store.recovery() }
        store.clearRecovery()
        check(store.recovery() == null)
        println("Self-test storage: 165 MB discard, notice, retention, UTF-8 limits, atomic replacement and recovery PASSED")
    } finally {
        directory.deleteRecursively()
    }
}
