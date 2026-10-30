package com.tntlikely.beecount

import org.json.JSONArray
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** 只执行内置的只读命令，不接受 Dart、页面或外部 Intent 提供的 shell 命令。 */
internal class RootBillingShell(private val apkPath: String) : AutoCloseable {
    private val reader = Executors.newSingleThreadExecutor()
    @Volatile private var current: Process? = null
    @Volatile private var closed = false

    fun checkRoot(): Boolean = run("id -u").trim() == "0"

    fun probeReader() {
        if (!readerOutput("com.tencent.mm", probe = true).lineSequence()
            .any { it == "BEECOUNT_ROOT_READY" }) throw RootReaderUnavailable("READER_UNAVAILABLE")
    }

    fun foreground(): Pair<String, String>? {
        return RootWindowPolicy.focus(run("dumpsys window displays"))
    }

    fun readNodes(packageName: String): List<String> {
        check(!closed)
        check(packageName in setOf("com.tencent.mm", "com.eg.android.AlipayGphone"))
        val output = readerOutput(packageName)
        val line = output.lineSequence().firstOrNull { it.startsWith("BEECOUNT_ROOT_NODES:") }
            ?: error("No Root reader result")
        val array = JSONArray(line.removePrefix("BEECOUNT_ROOT_NODES:"))
        check(array.length() <= 512)
        return (0 until array.length()).map { array.getString(it) }
    }

    private fun readerOutput(packageName: String, probe: Boolean = false): String {
        val command = "CLASSPATH=${quote(apkPath)} timeout 6 /system/bin/app_process /system/bin " +
            "com.tntlikely.beecount.RootBillingWindowReader ${quote(packageName)}" +
            (if (probe) " --probe" else "")
        val output = run(command, checkExit = false)
        if (output.lineSequence().any { it == "BEECOUNT_ROOT_ERROR:busy" }) {
            throw RootReaderUnavailable("READER_BUSY")
        }
        if (output.lineSequence().any { it.startsWith("BEECOUNT_ROOT_ERROR:") }) {
            throw RootReaderUnavailable("READER_UNAVAILABLE")
        }
        return output
    }

    private fun run(command: String, checkExit: Boolean = true): String {
        check(!closed)
        val process = ProcessBuilder("su", "-c", command).redirectErrorStream(true).start()
        current = process
        val output = reader.submit<String> {
            process.inputStream.use { stream ->
                val buffer = ByteArray(8192)
                val result = java.io.ByteArrayOutputStream()
                while (true) {
                    val size = stream.read(buffer)
                    if (size < 0) break
                    if (result.size() + size > 524288) error("Root output exceeded limit")
                    result.write(buffer, 0, size)
                }
                result.toString("UTF-8")
            }
        }
        try {
            check(process.waitFor(10, TimeUnit.SECONDS)) { "Root command timed out" }
            val text = output.get(2, TimeUnit.SECONDS)
            check(!checkExit || process.exitValue() == 0) { "Root command failed" }
            return text
        } finally {
            process.destroy()
            if (process.isAlive) process.destroyForcibly()
            output.cancel(true)
            current = null
        }
    }

    override fun close() {
        closed = true
        current?.destroy()
        reader.shutdownNow()
    }

    private fun quote(value: String) = "'" + value.replace("'", "'\\''") + "'"
}

internal class RootReaderUnavailable(val code: String) : Exception(code)

internal object RootWindowPolicy {
    fun focus(output: String): Pair<String, String>? {
        val match = Regex("mCurrentFocus=Window\\{[^\\n]*?\\s(?:[A-Za-z0-9]+:)?([A-Za-z0-9_.]+)/([^\\s}]+)")
            .find(output) ?: return null
        val packageName = match.groupValues[1]
        val activity = match.groupValues[2]
        return if (supports(packageName, activity)) packageName to activity else null
    }

    fun supports(packageName: String, activity: String): Boolean = when (packageName) {
        "com.tencent.mm" -> listOf("wallet", "remittance", "mallorder", "payui")
            .any { activity.contains(it, ignoreCase = true) }
        "com.eg.android.AlipayGphone" -> listOf("trade", "pay", "cashier", "h5activity")
            .any { activity.contains(it, ignoreCase = true) }
        else -> false
    }
}
