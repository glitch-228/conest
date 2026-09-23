package dev.conest.conest

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager

/** Wakes the already-enabled background runtime to dispatch a due schedule. */
class ScheduledMessageWakeupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != ACTION_SCHEDULED_MESSAGE_DUE) return
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val wakeLock = power.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "${context.packageName}:scheduled-message"
        )
        wakeLock.acquire(WAKE_LOCK_TIMEOUT_MS)
        MainActivity.requestScheduledMessagePump()
    }

    companion object {
        const val ACTION_SCHEDULED_MESSAGE_DUE =
            "dev.conest.action.SCHEDULED_MESSAGE_DUE"
        private const val WAKE_LOCK_TIMEOUT_MS = 20_000L
    }
}
