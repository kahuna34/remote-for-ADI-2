package de.markus.adi2_remote

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

/** Called only by the serial IO executor. Never read an unbounded report into a String. */
internal class AnalyzerSelfTestStore(private val directory: File) {
    companion object {
        const val WRITE_LIMIT = 1_000_000
        const val READ_LIMIT = 2_000_000
        const val RECOVERY_LIMIT = 64_000
        const val RECOVERY = "analyzer_selftest_recovery.json"
        private val reportName = Regex("analyzer_selftest_[0-9]+\\.json")
    }

    class TooLarge : IOException("Selbsttest-Datei zu groß")

    fun save(name: String, json: String): String {
        require(name == RECOVERY || reportName.matches(name))
        val limit = if (name == RECOVERY) RECOVERY_LIMIT else WRITE_LIMIT
        if (json.length >= limit) throw TooLarge()
        val bytes = json.toByteArray(Charsets.UTF_8)
        if (bytes.size >= limit) throw TooLarge()
        val file = File(directory, name)
        val temporary = File(directory, "$name.tmp")
        try {
            FileOutputStream(temporary).use { stream ->
                stream.write(bytes)
                stream.fd.sync()
            }
            check(temporary.renameTo(file)) { "Selbsttest-Datei konnte nicht ersetzt werden" }
        } finally {
            temporary.delete()
        }
        if (name != RECOVERY) cleanup()
        return "files/$name"
    }

    /** Delete old/oversized reports, but never remove the safety journal. */
    private fun cleanup(): Int {
        var discarded = 0
        val reports = directory.listFiles().orEmpty().filter { file ->
            if (file.isFile && file.name.endsWith(".tmp") &&
                reportName.matches(file.name.removeSuffix(".tmp"))) remove(file)
            file.isFile && reportName.matches(file.name)
        }.sortedByDescending { it.name }
        var kept = 0
        for (file in reports) {
            if (file.length() > READ_LIMIT) {
                remove(file)
                discarded++
            } else if (kept++ >= 5) remove(file)
        }
        return discarded
    }

    fun lastResult(): Map<String, String>? {
        var discarded = cleanup()
        val files = directory.listFiles().orEmpty()
            .filter { it.isFile && reportName.matches(it.name) }.sortedByDescending { it.name }
        for (file in files) {
            val json = try { readBounded(file, READ_LIMIT) } catch (_: TooLarge) {
                // Also guard against a file that grows after the size check.
                remove(file)
                discarded++
                continue
            }
            return mutableMapOf("path" to "files/${file.name}", "json" to json).apply {
                if (discarded > 0) put("notice", notice(discarded))
            }
        }
        return if (discarded > 0) mapOf("notice" to notice(discarded)) else null
    }

    fun recovery(): String? = File(directory, RECOVERY).takeIf { it.exists() }
        ?.let { readBounded(it, RECOVERY_LIMIT) }

    fun clearRecovery() {
        val file = File(directory, RECOVERY)
        if (file.exists()) remove(file)
    }

    private fun notice(count: Int) = "$count Selbsttest-Ergebnisdatei(en) zu groß, verworfen."
    private fun remove(file: File) {
        if (!file.delete()) throw IOException("Selbsttest-Datei konnte nicht entfernt werden: ${file.name}")
    }

    private fun readBounded(file: File, limit: Int): String {
        if (file.length() > limit) throw TooLarge()
        return file.inputStream().use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                if (output.size() + count > limit) throw TooLarge()
                output.write(buffer, 0, count)
            }
            output.toString("UTF-8")
        }
    }
}
