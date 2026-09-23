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
import android.content.pm.ServiceInfo

class ConestBackgroundService : Service() {
    private var backgroundEnabled = false
    private var transferActive = false
    private var transferTitle = "Transferring files"
    private var transferredBytes = 0L
    private var totalBytes = 0L
    private var transferPaused = false
    private var callsEnabled = false
    private var callTitle = ""
    private var callState = "idle"
    private var callIncoming = false
    private var voiceCallAudio: VoiceCallAudioEngine? = null
    private var voiceAudioLibraryLoaded = false
    private var voiceCallAudioStarting = false

    override fun onCreate() {
        super.onCreate()
        currentInstance = this
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        var callAudioHandle: Long? = null
        when (intent?.action) {
            ACTION_END_CALL -> {
                callTitle = ""
                callState = "idle"
                callIncoming = false
                stopVoiceCallAudio()
            }
            ACTION_UPDATE_PREFERENCES -> {
                backgroundEnabled = intent.getBooleanExtra(EXTRA_ENABLED, false)
                callsEnabled = intent.getBooleanExtra(EXTRA_CALLS_ENABLED, false)
            }
            ACTION_UPDATE_STATE -> {
                backgroundEnabled = intent.getBooleanExtra(EXTRA_ENABLED, false)
                callsEnabled = intent.getBooleanExtra(EXTRA_CALLS_ENABLED, false)
                callTitle = intent.getStringExtra(EXTRA_CALL_TITLE) ?: ""
                callState = intent.getStringExtra(EXTRA_CALL_STATE) ?: "idle"
                callIncoming = intent.getBooleanExtra(EXTRA_CALL_INCOMING, false)
                if (callState == "idle" || callState == "ended") {
                    stopVoiceCallAudio()
                }
            }
            ACTION_START_CALL_AUDIO -> {
                val handle = intent.getLongExtra(EXTRA_CALL_AUDIO_HANDLE, 0L)
                if (handle != 0L) {
                    if (callState == "idle" || callState == "ended") {
                        callState = "connecting"
                    }
                    voiceCallAudioStarting = true
                    callAudioHandle = handle
                }
            }
            ACTION_STOP_CALL_AUDIO -> stopVoiceCallAudio()
            ACTION_SET_CALL_SPEAKERPHONE -> {
                val enabled = intent.getBooleanExtra(EXTRA_CALL_SPEAKERPHONE, false)
                try {
                    voiceCallAudio?.setSpeakerphoneEnabled(enabled)
                } catch (error: Throwable) {
                    MainActivity.reportVoiceCallAudioFailure(
                        error.message ?: "Could not change the voice output."
                    )
                }
            }
            ACTION_UPDATE_TRANSFER -> {
                transferActive = true
                transferTitle = intent.getStringExtra(EXTRA_TITLE) ?: "Transferring files"
                transferredBytes = intent.getLongExtra(EXTRA_TRANSFERRED, 0L)
                totalBytes = intent.getLongExtra(EXTRA_TOTAL, 0L)
                transferPaused = intent.getBooleanExtra(EXTRA_PAUSED, false)
            }
            ACTION_STOP_TRANSFER -> transferActive = false
        }
        if (!backgroundEnabled && !callsEnabled && !hasCall() && !transferActive) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var types = 0
            if (transferActive || backgroundEnabled || callsEnabled || hasCall()) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            }
            if (callUsesMicrophone()) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            startForeground(NOTIFICATION_ID, buildNotification(), types)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }
        callAudioHandle?.let(::startVoiceCallAudio)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopVoiceCallAudio()
        if (currentInstance === this) currentInstance = null
        super.onDestroy()
    }

    private fun startVoiceCallAudio(handle: Long) {
        stopVoiceCallAudio()
        try {
            if (!voiceAudioLibraryLoaded) {
                System.loadLibrary("conest_native")
                voiceAudioLibraryLoaded = true
            }
            val engine = VoiceCallAudioEngine(
                context = this,
                handle = handle,
                pushCapture = ::nativeVoiceAudioPushCapture,
                readPlayback = ::nativeVoiceAudioReadPlayback,
                markFailed = ::nativeVoiceAudioMarkFailed,
                onFailure = MainActivity::reportVoiceCallAudioFailure,
            )
            engine.start()
            voiceCallAudio = engine
        } catch (error: Throwable) {
            stopVoiceCallAudio()
            MainActivity.reportVoiceCallAudioFailure(
                error.message ?: "Could not start Android voice audio."
            )
        } finally {
            voiceCallAudioStarting = false
        }
    }

    private fun stopVoiceCallAudio() {
        voiceCallAudioStarting = false
        voiceCallAudio?.stop()
        voiceCallAudio = null
    }

    private external fun nativeVoiceAudioPushCapture(
        handle: Long,
        samples: ShortArray,
        count: Int,
    ): Boolean

    private external fun nativeVoiceAudioReadPlayback(
        handle: Long,
        output: ShortArray,
        count: Int,
    ): Int

    private external fun nativeVoiceAudioMarkFailed(handle: Long)

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(
                this,
                if (hasCall()) CALL_CHANNEL_ID else MainActivity.BACKGROUND_CHANNEL_ID
            )
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_LOW)
        if (hasCall()) {
            builder
                .setCategory(Notification.CATEGORY_CALL)
                .setOnlyAlertOnce(callState != "ringing")
                .setContentTitle(
                    when (callState) {
                        "ringing" -> if (callIncoming) "Incoming Conest call" else "Calling"
                        "connecting", "reconnecting" -> "Conest call · $callState"
                        "connected" -> "Conest call in progress"
                        else -> "Conest voice call"
                    }
                )
                .setContentText(callTitle.ifBlank { "Tap to return to Conest" })
        } else if (transferActive) {
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
        } else if (callsEnabled) {
            builder
                .setContentTitle("Conest call availability")
                .setContentText("Ready for approved-contact calls while this service runs")
        } else {
            builder
                .setContentTitle("Conest background service")
                .setContentText("Conest keeps its active session available in the background")
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
        if (manager.getNotificationChannel(CALL_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CALL_CHANNEL_ID,
                    "Voice calls",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Incoming and active Conest voice calls"
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                }
            )
        }
    }

    private fun hasCall(): Boolean = callState != "idle" && callState != "ended"

    private fun callUsesMicrophone(): Boolean =
        voiceCallAudioStarting || voiceCallAudio != null

    companion object {
        private const val NOTIFICATION_ID = 6018
        const val ACTION_UPDATE_STATE = "dev.conest.action.UPDATE_STATE"
        const val ACTION_UPDATE_PREFERENCES = "dev.conest.action.UPDATE_PREFERENCES"
        const val ACTION_END_CALL = "dev.conest.action.END_CALL"
        const val ACTION_START_CALL_AUDIO = "dev.conest.action.START_CALL_AUDIO"
        const val ACTION_STOP_CALL_AUDIO = "dev.conest.action.STOP_CALL_AUDIO"
        const val ACTION_SET_CALL_SPEAKERPHONE =
            "dev.conest.action.SET_CALL_SPEAKERPHONE"
        const val ACTION_UPDATE_TRANSFER = "dev.conest.action.UPDATE_TRANSFER"
        const val ACTION_STOP_TRANSFER = "dev.conest.action.STOP_TRANSFER"
        const val EXTRA_ENABLED = "enabled"
        const val EXTRA_CALLS_ENABLED = "callsEnabled"
        const val EXTRA_CALL_TITLE = "callTitle"
        const val EXTRA_CALL_STATE = "callState"
        const val EXTRA_CALL_INCOMING = "callIncoming"
        const val EXTRA_CALL_AUDIO_HANDLE = "callAudioHandle"
        const val EXTRA_CALL_SPEAKERPHONE = "callSpeakerphone"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TRANSFERRED = "transferred"
        const val EXTRA_TOTAL = "total"
        const val EXTRA_PAUSED = "paused"
        const val EXTRA_TRANSFER_CONTROL = "transferControl"
        const val CONTROL_PAUSE_ALL = "pause_all"
        const val CONTROL_RESUME_ALL = "resume_all"
        const val CONTROL_CANCEL_ALL = "cancel_all"
        private const val CALL_CHANNEL_ID = "conest_calls"

        @Volatile
        private var currentInstance: ConestBackgroundService? = null

        fun shouldKeepFlutterRuntime(): Boolean {
            val service = currentInstance ?: return false
            return service.backgroundEnabled ||
                service.callsEnabled ||
                service.hasCall() ||
                service.transferActive
        }

        fun setVoiceCallSpeakerphoneEnabled(enabled: Boolean): Boolean {
            val service = currentInstance ?: return false
            val engine = service.voiceCallAudio ?: return false
            engine.setSpeakerphoneEnabled(enabled)
            return true
        }

        fun stopVoiceCallMedia() {
            currentInstance?.stopVoiceCallAudio()
        }
    }
}
