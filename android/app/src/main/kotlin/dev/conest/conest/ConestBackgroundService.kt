package dev.conest.conest

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

class ConestBackgroundService : Service() {
    private var backgroundEnabled = false
    private var transferActive = false
    private var transferTitle = "Transferring files"
    private var transferredBytes = 0L
    private var totalBytes = 0L
    private var transferPaused = false

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_BACKGROUND -> backgroundEnabled = intent.getBooleanExtra(EXTRA_ENABLED, false)
            ACTION_UPDATE_TRANSFER -> {
                transferActive = true
                transferTitle = intent.getStringExtra(EXTRA_TITLE) ?: "Transferring files"
                transferredBytes = intent.getLongExtra(EXTRA_TRANSFERRED, 0L)
                totalBytes = intent.getLongExtra(EXTRA_TOTAL, 0L)
                transferPaused = intent.getBooleanExtra(EXTRA_PAUSED, false)
            }
            ACTION_STOP_TRANSFER -> transferActive = false
        }
        if (!backgroundEnabled && !transferActive) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, MainActivity.BACKGROUND_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_LOW)
        if (transferActive) {
            val progress = if (totalBytes > 0) {
                ((transferredBytes.coerceIn(0L, totalBytes) * 1000L) / totalBytes).toInt()
            } else 0
            builder
                .setContentTitle(transferTitle)
                .setContentText(
                    if (transferPaused) "Paused" else "${progress / 10}% · Conest stays active"
                )
                .setProgress(1000, progress, totalBytes <= 0)
                .addAction(
                    action(
                        if (transferPaused) "Resume all" else "Pause all",
                        if (transferPaused) CONTROL_RESUME_ALL else CONTROL_PAUSE_ALL,
                        1
                    )
                )
                .addAction(action("Cancel all", CONTROL_CANCEL_ALL, 2))
        } else {
            builder
                .setContentTitle("Conest background service")
                .setContentText("Reopen Conest to receive messages.")
        }
        return builder.build()
    }

    private fun action(title: String, control: String, requestCode: Int): Notification.Action {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_TRANSFER_CONTROL, control)
        }
        val pending = PendingIntent.getActivity(
            this,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        @Suppress("DEPRECATION")
        return Notification.Action.Builder(0, title, pending).build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(MainActivity.BACKGROUND_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    MainActivity.BACKGROUND_CHANNEL_ID,
                    "Background runtime",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
    }

    companion object {
        private const val NOTIFICATION_ID = 6018
        const val ACTION_BACKGROUND = "dev.conest.action.BACKGROUND"
        const val ACTION_UPDATE_TRANSFER = "dev.conest.action.UPDATE_TRANSFER"
        const val ACTION_STOP_TRANSFER = "dev.conest.action.STOP_TRANSFER"
        const val EXTRA_ENABLED = "enabled"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TRANSFERRED = "transferred"
        const val EXTRA_TOTAL = "total"
        const val EXTRA_PAUSED = "paused"
        const val EXTRA_TRANSFER_CONTROL = "transferControl"
        const val CONTROL_PAUSE_ALL = "pause_all"
        const val CONTROL_RESUME_ALL = "resume_all"
        const val CONTROL_CANCEL_ALL = "cancel_all"
    }
}
