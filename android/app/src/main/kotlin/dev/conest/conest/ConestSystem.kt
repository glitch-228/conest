package dev.conest.conest

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// What the system channel does without a screen: notifications, the
/// background service, scheduled wake-ups, power state and the battery
/// exemption. The activity answers these the same way, and a headless
/// engine (started by the background service, with no activity) answers
/// only these.
object ConestSystem {
    const val CHANNEL = "dev.conest.conest/system"
    const val MESSAGES_CHANNEL_ID = "conest_messages"
    const val BACKGROUND_CHANNEL_ID = "conest_background"
    const val GROUPS_CHANNEL_ID = "conest_groups"
    /// Messages during quiet hours: shown without sound or vibration.
    const val QUIET_CHANNEL_ID = "conest_quiet"
    private const val SCHEDULED_MESSAGE_WAKEUP_REQUEST = 6019
    private const val GROUP_KEY_MESSAGES = "dev.conest.conest.messages"
    private const val SUMMARY_NOTIFICATION_ID = 0x100b1ade

    /// The error code for a request that needs an activity to ask on.
    const val NEEDS_SCREEN = "needs_screen"

    /// Answers [call] when it needs no activity; false when it does.
    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "setBackgroundRuntimeEnabled" -> {
                updateBackgroundServicePreferences(
                    context,
                    call.argument<Boolean>("enabled") == true,
                    call.argument<Boolean>("callsEnabled") == true,
                    persist = call.argument<Boolean>("persist") != false,
                )
                result.success(null)
            }
            "updateVoiceCallForeground" -> {
                updateBackgroundServiceState(
                    context,
                    call.argument<Boolean>("runtimeEnabled") == true,
                    call.argument<Boolean>("callsEnabled") == true,
                    call.argument<String>("peerName"),
                    call.argument<String>("callState") ?: "idle",
                    call.argument<Boolean>("incoming") == true,
                )
                result.success(null)
            }
            "scheduleScheduledMessageWakeup" -> {
                try {
                    scheduleScheduledMessageWakeup(
                        context,
                        call.argument<Number>("timestampMs")?.toLong(),
                    )
                    result.success(null)
                } catch (error: Throwable) {
                    result.error(
                        "scheduled_wakeup_failed",
                        error.message ?: "Could not schedule the background send.",
                        null
                    )
                }
            }
            "showMessageNotification" -> {
                val title = call.argument<String>("title") ?: "Conest"
                @Suppress("UNCHECKED_CAST")
                showMessageNotification(
                    context,
                    title,
                    call.argument<String>("body") ?: "New message",
                    call.argument<String>("conversationId") ?: title,
                    call.argument<String>("senderName") ?: title,
                    call.argument<String>("selfName") ?: "me",
                    call.argument<List<Map<String, Any?>>>("recentMessages") ?: emptyList(),
                    replyLabel = call.argument<String>("replyLabel"),
                    markReadLabel = call.argument<String>("markReadLabel"),
                    throughMessageId = call.argument<String>("throughMessageId"),
                    silent = call.argument<Boolean>("silent") == true,
                    group = call.argument<Boolean>("group") == true,
                )
                result.success(null)
            }
            "takePendingNotificationActions" -> {
                result.success(NotificationActionReceiver.takePending(context))
            }
            "notificationActionsDone" -> {
                ConestBackgroundService.finishNotificationWork()
                result.success(null)
            }
            "dismissMessageNotification" -> {
                dismissMessageNotification(context, call.argument<String>("conversationId") ?: "")
                result.success(null)
            }
            "updateTransferForeground" -> {
                val transferred = call.argument<Number>("transferredBytes")?.toLong() ?: 0L
                val total = call.argument<Number>("totalBytes")?.toLong() ?: 0L
                val serviceIntent = Intent(context, ConestBackgroundService::class.java).apply {
                    action = ConestBackgroundService.ACTION_UPDATE_TRANSFER
                    putExtra(
                        ConestBackgroundService.EXTRA_TITLE,
                        call.argument<String>("title") ?: "Transferring files"
                    )
                    putExtra(ConestBackgroundService.EXTRA_TRANSFERRED, transferred)
                    putExtra(ConestBackgroundService.EXTRA_TOTAL, total)
                    putExtra(
                        ConestBackgroundService.EXTRA_PAUSED,
                        call.argument<Boolean>("paused") == true
                    )
                }
                startConestForegroundService(context, serviceIntent)
                result.success(null)
            }
            "stopTransferForeground" -> {
                // Nothing to stop when the service is not running, and
                // starting a service from the background throws on Android
                // 8+ (each transfer that ended with the screen off was
                // recorded as a crash).
                if (ConestBackgroundService.isRunning()) {
                    try {
                        context.startService(
                            Intent(context, ConestBackgroundService::class.java).apply {
                                action = ConestBackgroundService.ACTION_STOP_TRANSFER
                            }
                        )
                    } catch (error: IllegalStateException) {
                        ConestBackgroundService.stopTransferDirectly()
                    }
                }
                result.success(null)
            }
            "nativeLibraryDir" -> result.success(context.applicationInfo.nativeLibraryDir)
            "takeExitReports" -> result.success(CrashReports.takeExitReports(context))
            "powerState" -> result.success(powerState(context))
            "batteryOptimizationExempt" -> result.success(batteryOptimizationExempt(context))
            "requestBatteryOptimizationExemption" ->
                result.success(requestBatteryOptimizationExemption(context))
            "deviceManufacturer" -> result.success(Build.MANUFACTURER ?: "")
            // These need a screen to ask on: without one they say so, never
            // "not implemented".
            "requestBluetoothPermissions",
            "requestVoiceCallMicrophonePermission",
            "requestNotificationPermission" -> result.error(
                NEEDS_SCREEN,
                "Open Conest to allow this.",
                null
            )
            else -> return false
        }
        return true
    }

    fun startConestForegroundService(context: Context, intent: Intent) {
        ensureNotificationChannels(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    fun updateBackgroundServiceState(
        context: Context,
        runtimeEnabled: Boolean,
        callsEnabled: Boolean,
        peerName: String?,
        callState: String,
        incoming: Boolean,
    ) {
        val intent = Intent(context, ConestBackgroundService::class.java).apply {
            action = ConestBackgroundService.ACTION_UPDATE_STATE
            putExtra(ConestBackgroundService.EXTRA_ENABLED, runtimeEnabled)
            putExtra(ConestBackgroundService.EXTRA_CALLS_ENABLED, callsEnabled)
            putExtra(ConestBackgroundService.EXTRA_CALL_TITLE, peerName ?: "")
            putExtra(ConestBackgroundService.EXTRA_CALL_STATE, callState)
            putExtra(ConestBackgroundService.EXTRA_CALL_INCOMING, incoming)
        }
        // A foreground start only when there is something to show (the
        // runtime, calls, or a call in progress); otherwise a plain update.
        val callInProgress = callState != "idle" && callState != "ended"
        if (runtimeEnabled || callsEnabled || callInProgress) {
            startConestForegroundService(context, intent)
        } else {
            try {
                context.startService(intent)
            } catch (error: IllegalStateException) {
                // In the background with nothing to run: nothing to update.
            }
        }
    }

    fun updateBackgroundServicePreferences(
        context: Context,
        runtimeEnabled: Boolean,
        callsEnabled: Boolean,
        persist: Boolean = true,
    ) {
        // Kept for a restart without the app (the process killed, a reboot,
        // an update): the service reads them back.
        if (persist) {
            ConestBackgroundService.savePreferences(context, runtimeEnabled, callsEnabled)
        }
        val intent = Intent(context, ConestBackgroundService::class.java).apply {
            action = ConestBackgroundService.ACTION_UPDATE_PREFERENCES
            putExtra(ConestBackgroundService.EXTRA_ENABLED, runtimeEnabled)
            putExtra(ConestBackgroundService.EXTRA_CALLS_ENABLED, callsEnabled)
            putExtra(ConestBackgroundService.EXTRA_PERSIST, persist)
        }
        if (runtimeEnabled || callsEnabled) {
            startConestForegroundService(context, intent)
        } else {
            try {
                context.startService(intent)
            } catch (error: IllegalStateException) {
                // Not running and nothing to run.
            }
        }
    }

    fun scheduleScheduledMessageWakeup(context: Context, timestampMs: Long?) {
        val alarmManager =
            context.getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
        val intent = Intent(context, ScheduledMessageWakeupReceiver::class.java).apply {
            action = ScheduledMessageWakeupReceiver.ACTION_SCHEDULED_MESSAGE_DUE
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            SCHEDULED_MESSAGE_WAKEUP_REQUEST,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        if (timestampMs == null) {
            alarmManager.cancel(pendingIntent)
            pendingIntent.cancel()
            return
        }
        val triggerAt = maxOf(timestampMs, System.currentTimeMillis())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            alarmManager.setAndAllowWhileIdle(
                android.app.AlarmManager.RTC_WAKEUP,
                triggerAt,
                pendingIntent
            )
        } else {
            alarmManager.setExact(
                android.app.AlarmManager.RTC_WAKEUP,
                triggerAt,
                pendingIntent
            )
        }
    }

    fun showMessageNotification(
        context: Context,
        title: String,
        body: String,
        conversationId: String,
        senderName: String,
        selfName: String,
        recentMessages: List<Map<String, Any?>>,
        replyLabel: String? = null,
        markReadLabel: String? = null,
        throughMessageId: String? = null,
        silent: Boolean = false,
        group: Boolean = false,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureNotificationChannels(context)
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_NEW_TASK
            putExtra("conversationId", conversationId)
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            conversationId.hashCode(),
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val channel = when {
            silent -> QUIET_CHANNEL_ID
            group -> GROUPS_CHANNEL_ID
            else -> MESSAGES_CHANNEL_ID
        }
        val builder = notificationBuilder(context, channel)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setGroup(GROUP_KEY_MESSAGES)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val self = Person.Builder().setName(selfName).build()
            val style = Notification.MessagingStyle(self).setConversationTitle(title)
            if (recentMessages.isEmpty()) {
                val sender = Person.Builder().setName(senderName).build()
                style.addMessage(
                    Notification.MessagingStyle.Message(body, System.currentTimeMillis(), sender)
                )
            } else {
                for (entry in recentMessages) {
                    val text = entry["body"] as? String ?: ""
                    val ts = (entry["timestampMs"] as? Number)?.toLong()
                        ?: System.currentTimeMillis()
                    val sender = Person.Builder()
                        .setName(entry["sender"] as? String ?: senderName)
                        .build()
                    style.addMessage(Notification.MessagingStyle.Message(text, ts, sender))
                }
            }
            builder.setStyle(style)
        } else {
            builder.setStyle(Notification.BigTextStyle().bigText(body))
        }
        // Reply and "Mark as read" right from the notification (Android 7+).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            if (!replyLabel.isNullOrBlank()) {
                val input = android.app.RemoteInput.Builder(NotificationActionReceiver.KEY_REPLY)
                    .setLabel(replyLabel)
                    .build()
                builder.addAction(
                    Notification.Action.Builder(
                        null,
                        replyLabel,
                        NotificationActionReceiver.pendingIntent(
                            context,
                            conversationId,
                            NotificationActionReceiver.ACTION_REPLY,
                            throughMessageId,
                            mutable = true,
                        )
                    ).addRemoteInput(input).setAllowGeneratedReplies(false)
                        .requireUnlock().build()
                )
            }
            if (!markReadLabel.isNullOrBlank()) {
                builder.addAction(
                    Notification.Action.Builder(
                        null,
                        markReadLabel,
                        NotificationActionReceiver.pendingIntent(
                            context,
                            conversationId,
                            NotificationActionReceiver.ACTION_MARK_READ,
                            throughMessageId,
                            mutable = false,
                        )
                    ).requireUnlock().build()
                )
            }
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(conversationId.hashCode(), builder.build())
        postOrRefreshGroupSummary(context, manager)
    }

    /// Not from a locked phone: a reply or a read sent from the lock screen
    /// needs the phone unlocked first (Android 12+).
    private fun Notification.Action.Builder.requireUnlock(): Notification.Action.Builder {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) setAuthenticationRequired(true)
        return this
    }

    fun dismissMessageNotification(context: Context, conversationId: String) {
        if (conversationId.isEmpty()) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(conversationId.hashCode())
        maybeCancelGroupSummary(manager)
    }

    private fun postOrRefreshGroupSummary(context: Context, manager: NotificationManager) {
        // The summary never sounds itself (a re-post on the sounding
        // channel would defeat quiet hours and a muted chat): it sits on the
        // quiet channel, and only the children alert.
        val builder = notificationBuilder(context, QUIET_CHANNEL_ID)
            .setContentTitle("Conest")
            .setContentText("New messages")
            .setGroup(GROUP_KEY_MESSAGES)
            .setGroupSummary(true)
            .setOnlyAlertOnce(true)
            .setAutoCancel(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
        }
        val summary = builder.build()
        manager.notify(SUMMARY_NOTIFICATION_ID, summary)
    }

    private fun maybeCancelGroupSummary(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }
        val anyChildRemains = manager.activeNotifications.any { sbn ->
            sbn.id != SUMMARY_NOTIFICATION_ID &&
                sbn.notification.group == GROUP_KEY_MESSAGES
        }
        if (!anyChildRemains) {
            manager.cancel(SUMMARY_NOTIFICATION_ID)
        }
    }

    /** Battery, charging and battery saver, for how many routes messages use. */
    fun powerState(context: Context): Map<String, Any?> {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val present = battery?.getBooleanExtra(BatteryManager.EXTRA_PRESENT, true) ?: true
        val plugged = battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "hasBattery" to present,
            "charging" to if (battery == null) null else plugged > 0,
            "batteryPercent" to if (level >= 0 && scale > 0) level * 100 / scale else null,
            "batterySaver" to power.isPowerSaveMode,
        )
    }

    /// Whether Android leaves Conest out of battery optimisation (Doze and
    /// App Standby then do not cut it off in the background).
    fun batteryOptimizationExempt(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return power.isIgnoringBatteryOptimizations(context.packageName)
    }

    /// Opens Android's prompt to leave Conest out of battery optimisation
    /// (or, where it is missing, the list to choose it in). False when
    /// neither opens.
    fun requestBatteryOptimizationExemption(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val direct = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${context.packageName}")
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val list = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        for (intent in listOf(direct, list)) {
            try {
                context.startActivity(intent)
                return true
            } catch (error: Exception) {
                // Some vendors leave one of them out: try the next.
            }
        }
        return false
    }

    fun notificationBuilder(context: Context, channelId: String): Notification.Builder {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_conest)
            .setColor(0xFF04F6AF.toInt())
            .setPriority(Notification.PRIORITY_DEFAULT)
    }

    fun ensureNotificationChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(MESSAGES_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    MESSAGES_CHANNEL_ID,
                    "Messages",
                    NotificationManager.IMPORTANCE_DEFAULT
                )
            )
        }
        if (manager.getNotificationChannel(BACKGROUND_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    BACKGROUND_CHANNEL_ID,
                    "Background runtime",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        // Each kind its own channel, so Android's settings can give groups
        // another sound (or none) than chats.
        if (manager.getNotificationChannel(GROUPS_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    GROUPS_CHANNEL_ID,
                    "Group messages",
                    NotificationManager.IMPORTANCE_DEFAULT
                )
            )
        }
        if (manager.getNotificationChannel(QUIET_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    QUIET_CHANNEL_ID,
                    "Messages during quiet hours",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    setSound(null, null)
                    enableVibration(false)
                }
            )
        }
    }
}
