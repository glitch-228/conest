package dev.conest.conest

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/**
 * Keeps crashes from going unnoticed (lib/src/crash_catcher.dart reads both):
 * a Java or Kotlin crash is written to `crash/native-crash.txt` in the app's
 * files before the process ends, and the next start asks Android why earlier
 * runs ended (native crashes, freezes) through ApplicationExitInfo.
 */
object CrashReports {
    private const val MAX_TEXT = 8000
    private const val PREFS = "conest_crash"
    private const val SEEN_KEY = "exitSeenAt"

    @Volatile
    private var installed = false

    fun install(context: Context) {
        if (installed) return
        installed = true
        val file = File(File(context.applicationContext.filesDir, "crash"), "native-crash.txt")
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                file.parentFile?.mkdirs()
                val trace = StringWriter().also { error.printStackTrace(PrintWriter(it)) }
                file.appendText(
                    "Android crash on thread '${thread.name}': " +
                        trace.toString().take(MAX_TEXT) + "\n\n"
                )
            } catch (_: Throwable) {
                // Nothing more can be done while the process ends.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    /** Why earlier runs ended badly, each reported once. */
    fun takeExitReports(context: Context): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val seen = prefs.getLong(SEEN_KEY, 0L)
        val manager = context.getSystemService(ActivityManager::class.java) ?: return emptyList()
        val exits = try {
            manager.getHistoricalProcessExitReasons(context.packageName, 0, 16)
        } catch (_: Exception) {
            return emptyList()
        }
        var newest = seen
        val reports = mutableListOf<Map<String, Any?>>()
        for (exit in exits) {
            if (exit.timestamp <= seen) continue
            newest = maxOf(newest, exit.timestamp)
            val kind = when (exit.reason) {
                ApplicationExitInfo.REASON_CRASH -> "crash"
                ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
                ApplicationExitInfo.REASON_ANR -> "stopped responding"
                ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "failed to start"
                else -> null
            } ?: continue
            // ANR traces are text; native crash tombstones are binary.
            val trace = if (exit.reason == ApplicationExitInfo.REASON_ANR) {
                try {
                    exit.traceInputStream?.use { stream ->
                        String(stream.readNBytesCompat(MAX_TEXT))
                    }
                } catch (_: Exception) {
                    null
                }
            } else {
                null
            }
            reports += mapOf(
                "at" to exit.timestamp,
                "kind" to kind,
                "description" to exit.description,
                "trace" to trace,
            )
        }
        if (newest != seen) prefs.edit().putLong(SEEN_KEY, newest).apply()
        return reports
    }

    private fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
        val buffer = ByteArray(limit)
        var read = 0
        while (read < limit) {
            val count = read(buffer, read, limit - read)
            if (count < 0) break
            read += count
        }
        return buffer.copyOf(read)
    }
}
