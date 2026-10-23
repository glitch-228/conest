package dev.conest.conest

import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/// Reply and "Mark as read" from a message notification: given to Dart at
/// once when Conest runs, or kept (on disk, until Dart takes it) while its
/// engine starts without a screen. Conest stays in the foreground meanwhile.
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val conversationId = intent.getStringExtra(EXTRA_CONVERSATION) ?: return
        val action = intent.getStringExtra(EXTRA_ACTION) ?: return
        val text = RemoteInput.getResultsFromIntent(intent)
            ?.getCharSequence(KEY_REPLY)
            ?.toString()
        // Handled (or nothing to send): the notification goes, so a reply
        // does not keep spinning. Dart shows it again if a reply fails.
        ConestSystem.dismissMessageNotification(context, conversationId)
        if (action == ACTION_REPLY && text.isNullOrBlank()) return
        val event = mapOf(
            "conversationId" to conversationId,
            "action" to action,
            "text" to text,
            "throughMessageId" to intent.getStringExtra(EXTRA_THROUGH),
        )
        val app = context.applicationContext
        var given = false
        val channel = ConestEngine.systemChannel
        if (channel != null && ConestEngine.cached() != null) {
            try {
                // Dart not listening yet (still starting): kept for it.
                channel.invokeMethod("notificationAction", event, object : MethodChannel.Result {
                    override fun success(result: Any?) {}
                    override fun error(code: String, message: String?, details: Any?) =
                        keep(app, event)
                    override fun notImplemented() = keep(app, event)
                })
                given = true
            } catch (_: RuntimeException) {
                // The engine is going away: kept below.
            }
        }
        if (!given) keep(app, event)
        if (!ConestBackgroundService.startNotificationWork(app)) {
            try {
                ConestEngine.ensureRunning(app)
            } catch (error: Throwable) {
                android.util.Log.w("Conest", "Engine not started for a notification action: $error")
            }
        }
    }

    companion object {
        const val KEY_REPLY = "conest_reply"
        const val ACTION_REPLY = "reply"
        const val ACTION_MARK_READ = "markRead"
        private const val EXTRA_CONVERSATION = "conversationId"
        private const val EXTRA_ACTION = "action"
        private const val EXTRA_THROUGH = "throughMessageId"
        private const val MAX_PENDING = 32
        private const val PREFERENCES = "conest_notification_actions"
        private const val PREF_PENDING = "pending"
        private val lock = Any()

        private fun preferences(context: Context) =
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

        private fun keep(context: Context, event: Map<String, Any?>) {
            synchronized(lock) {
                val prefs = preferences(context)
                val pending = try {
                    JSONArray(prefs.getString(PREF_PENDING, "[]"))
                } catch (_: Exception) {
                    JSONArray()
                }
                if (pending.length() >= MAX_PENDING) return
                val entry = JSONObject()
                for ((key, value) in event) entry.put(key, value ?: JSONObject.NULL)
                pending.put(entry)
                prefs.edit().putString(PREF_PENDING, pending.toString()).commit()
            }
        }

        /// What came while Conest was not running, for Dart to handle.
        fun takePending(context: Context): List<Map<String, Any?>> = synchronized(lock) {
            val prefs = preferences(context)
            val pending = try {
                JSONArray(prefs.getString(PREF_PENDING, "[]"))
            } catch (_: Exception) {
                JSONArray()
            }
            prefs.edit().remove(PREF_PENDING).commit()
            (0 until pending.length()).mapNotNull { index ->
                val entry = pending.optJSONObject(index) ?: return@mapNotNull null
                entry.keys().asSequence().associateWith { key ->
                    if (entry.isNull(key)) null else entry.optString(key)
                }
            }
        }

        fun pendingIntent(
            context: Context,
            conversationId: String,
            action: String,
            throughMessageId: String?,
            mutable: Boolean,
        ): PendingIntent {
            val intent = Intent(context, NotificationActionReceiver::class.java).apply {
                // Its own data per chat and action: two chats never share
                // (and overwrite) one PendingIntent.
                data = Uri.Builder()
                    .scheme("conest-notification")
                    .authority(action)
                    .appendPath(conversationId)
                    .build()
                putExtra(EXTRA_CONVERSATION, conversationId)
                putExtra(EXTRA_ACTION, action)
                putExtra(EXTRA_THROUGH, throughMessageId)
            }
            // A reply's text is filled in by the system, so that one must
            // be mutable (explicitly from Android 12, by default before).
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or when {
                !mutable -> PendingIntent.FLAG_IMMUTABLE
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> PendingIntent.FLAG_MUTABLE
                else -> 0
            }
            return PendingIntent.getBroadcast(
                context,
                (conversationId + action).hashCode(),
                intent,
                flags
            )
        }
    }
}
