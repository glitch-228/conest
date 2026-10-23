package dev.conest.conest

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/// After a reboot or an update, Conest runs again in the background (when
/// it was running there), without being opened.
class ConestBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        if (!ConestBackgroundService.backgroundWanted(context)) return
        try {
            ConestSystem.startConestForegroundService(
                context,
                Intent(context, ConestBackgroundService::class.java).apply {
                    action = ConestBackgroundService.ACTION_RESTORE
                }
            )
        } catch (error: Exception) {
            android.util.Log.w("Conest", "Background service not started after boot: $error")
        }
    }
}
