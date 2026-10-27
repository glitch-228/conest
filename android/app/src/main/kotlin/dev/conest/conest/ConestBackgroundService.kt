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

    /// The microphone test of Settings → Voice has the audio: no call
    /// state, so no "call connecting" notice, but the service stays up.
    private var microphoneTest = false

    /// Answer on the ringing notification works with this token only: the
    /// activity is exported, so another app could send a bare answer.
    @Volatile
    private var ringToken: String? = null

    /// The ringing notification already alerted (full screen, sound) for
    /// this ring; later posts only update it.
    private var ringAnnounced = false

    /// A reply or "Mark as read" from a notification being handled: Conest
    /// stays in the foreground until Dart is done, so Android does not end
    /// the process first.
    private var notificationWork = false
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val endNotificationWork = Runnable {
        notificationWork = false
        if (!backgroundEnabled && !callsEnabled && !hasCall() && !transferActive &&
            !microphoneTest
        ) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        } else {
            promoteToForeground()
        }
    }

    override fun onCreate() {
        super.onCreate()
        CrashReports.install(this)
        currentInstance = this
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        var callAudioHandle: Long? = null
        when (intent?.action) {
            // Started again by Android (START_STICKY, no intent), after a
            // reboot or an update: as the app last asked.
            null, ACTION_RESTORE -> {
                val preferences = preferences(this)
                backgroundEnabled = preferences.getBoolean(PREF_ENABLED, false)
                callsEnabled = preferences.getBoolean(PREF_CALLS_ENABLED, false)
            }
            ACTION_END_CALL -> {
                callTitle = ""
                callState = "idle"
                callIncoming = false
                stopVoiceCallAudio()
            }
            ACTION_UPDATE_PREFERENCES -> {
                backgroundEnabled = intent.getBooleanExtra(EXTRA_ENABLED, false)
                callsEnabled = intent.getBooleanExtra(EXTRA_CALLS_ENABLED, false)
                if (intent.getBooleanExtra(EXTRA_PERSIST, true)) {
                    savePreferences(this, backgroundEnabled, callsEnabled)
                }
            }
            ACTION_UPDATE_STATE -> {
                backgroundEnabled = intent.getBooleanExtra(EXTRA_ENABLED, false)
                callsEnabled = intent.getBooleanExtra(EXTRA_CALLS_ENABLED, false)
                savePreferences(this, backgroundEnabled, callsEnabled)
                callTitle = intent.getStringExtra(EXTRA_CALL_TITLE) ?: ""
                callState = intent.getStringExtra(EXTRA_CALL_STATE) ?: "idle"
                callIncoming = intent.getBooleanExtra(EXTRA_CALL_INCOMING, false)
                if (callState == "idle" || callState == "ended") {
                    stopVoiceCallAudio()
                }
            }
            ACTION_START_CALL_AUDIO -> {
                val handle = intent.getLongExtra(EXTRA_CALL_AUDIO_HANDLE, 0L)
                // Dart may close (and free) the native handle before this
                // queued intent runs. Only start the handle still requested.
                if (handle != 0L && handle == requestedCallAudioHandle) {
                    if (intent.getBooleanExtra(EXTRA_CALL_AUDIO_TEST, false)) {
                        if (!hasCall()) microphoneTest = true
                    } else if (callState == "idle" || callState == "ended") {
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
            ACTION_NOTIFICATION_WORK -> {
                notificationWork = true
                // Never longer than this, even if Dart cannot finish (a
                // profile locked by a passphrase).
                mainHandler.removeCallbacks(endNotificationWork)
                mainHandler.postDelayed(endNotificationWork, NOTIFICATION_WORK_LIMIT_MS)
            }
        }
        updateRing()
        if (!backgroundEnabled && !callsEnabled && !hasCall() && !transferActive &&
            !notificationWork && !microphoneTest
        ) {
            // Started with startForegroundService, a service must call
            // startForeground before it stops, even with nothing to show;
            // otherwise Android kills the app (ForegroundServiceDidNot-
            // StartInTimeException).
            promoteToForeground()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        promoteToForeground()
        if (backgroundEnabled || callsEnabled || notificationWork) {
            // Conest runs without its screen: the same engine the activity
            // shows when it opens.
            try {
                ConestEngine.ensureRunning(this)
            } catch (error: Throwable) {
                android.util.Log.w("Conest", "Background engine not started: $error")
            }
        }
        callAudioHandle?.let(::startVoiceCallAudio)
        return START_STICKY
    }

    private fun promoteToForeground() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Messaging from Android 14 on: data sync is capped at six
                // hours a day (Android 15) and may not start at boot.
                var types = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING
                } else {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                }
                if (callUsesMicrophone()) {
                    types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                startForeground(NOTIFICATION_ID, buildNotification(), types)
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
        } catch (error: Exception) {
            // Not allowed now (for example from the background on newer
            // Android): the service carries on without its notification.
            android.util.Log.w("Conest", "Foreground service not started: $error")
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        mainHandler.removeCallbacks(endNotificationWork)
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
                noiseEnabled = ::nativeVoiceAudioNoiseEnabled,
                platformNoise = ::nativeVoiceAudioPlatformNoise,
                echoEnabled = ::nativeVoiceAudioEchoEnabled,
                markFailed = ::nativeVoiceAudioMarkFailed,
                onFailure = MainActivity::reportVoiceCallAudioFailure,
            )
            engine.start()
            voiceCallAudio = engine
            requestedSpeakerphone?.let { enabled ->
                try {
                    engine.setSpeakerphoneEnabled(enabled)
                } catch (error: Throwable) {
                    MainActivity.reportVoiceCallAudioFailure(
                        error.message ?: "Could not change the voice output."
                    )
                }
            }
        } catch (error: Throwable) {
            stopVoiceCallAudio()
            MainActivity.reportVoiceCallAudioFailure(
                error.message ?: "Could not start Android voice audio."
            )
        } finally {
            voiceCallAudioStarting = false
        }
    }

    /// A new incoming ring gets a new token; no ring, no token.
    private fun updateRing() {
        val ringing = callState == "ringing"
        if (!ringing) ringAnnounced = false
        if (ringing && callIncoming) {
            if (ringToken == null) {
                val bytes = ByteArray(16)
                java.security.SecureRandom().nextBytes(bytes)
                ringToken = bytes.joinToString("") { "%02x".format(it) }
            }
        } else {
            ringToken = null
        }
    }

    private fun stopVoiceCallAudio() {
        microphoneTest = false
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

    private external fun nativeVoiceAudioNoiseEnabled(handle: Long): Boolean
    private external fun nativeVoiceAudioPlatformNoise(handle: Long, enabled: Boolean)
    private external fun nativeVoiceAudioEchoEnabled(handle: Long): Boolean

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
                when {
                    hasCall() -> CALL_CHANNEL_ID
                    transferActive -> TRANSFERS_CHANNEL_ID
                    else -> MainActivity.BACKGROUND_CHANNEL_ID
                }
            )
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_conest)
            .setColor(0xFF04F6AF.toInt())
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setPriority(Notification.PRIORITY_LOW)
        if (hasCall()) {
            builder
                .setCategory(Notification.CATEGORY_CALL)
                // Only the first post of a ring alerts; later ones (any
                // service command re-posts) just update it.
                .setOnlyAlertOnce(callState != "ringing" || ringAnnounced)
                .setContentTitle(
                    when (callState) {
                        "ringing" -> if (callIncoming) "Incoming Conest call" else "Calling"
                        "connecting", "reconnecting" -> "Conest call · $callState"
                        "connected" -> "Conest call in progress"
                        else -> "Conest voice call"
                    }
                )
                .setContentText(callTitle.ifBlank { "Tap to return to Conest" })
            if (callState == "ringing" && callIncoming) {
                // Over the lock screen and with the screen off, as a phone
                // call; Answer and Decline right in it.
                if (!ringAnnounced) builder.setFullScreenIntent(pendingIntent, true)
                builder.addAction(callAction("Decline", NotificationActionReceiver.ACTION_CALL_DECLINE))
                builder.addAction(answerAction())
            }
            if (callState == "ringing") ringAnnounced = true
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
        } else if (microphoneTest) {
            builder
                .setContentTitle("Conest")
                .setContentText("Testing the microphone")
        } else if (notificationWork && !backgroundEnabled && !callsEnabled) {
            builder
                .setContentTitle("Conest")
                .setContentText("Sending…")
        } else if (callsEnabled) {
            builder
                .setContentTitle("Conest call availability")
                .setContentText("Ready for approved-contact calls while this service runs")
        } else {
            builder
                .setContentTitle("Conest is receiving messages")
                .setContentText("Messages arrive while Conest is closed")
        }
        return builder.build()
    }

    private fun answerAction(): Notification.Action {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_CALL_ANSWER, true)
            putExtra(EXTRA_CALL_ANSWER_TOKEN, ringToken ?: "")
        }
        val pending = PendingIntent.getActivity(
            this,
            3,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        @Suppress("DEPRECATION")
        return Notification.Action.Builder(0, "Answer", pending).build()
    }

    private fun callAction(title: String, action: String): Notification.Action {
        @Suppress("DEPRECATION")
        return Notification.Action.Builder(
            0,
            title,
            NotificationActionReceiver.pendingIntent(
                this,
                NotificationActionReceiver.CALL_CONVERSATION,
                action,
                null,
                mutable = false,
            ),
        ).build()
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
        if (manager.getNotificationChannel(TRANSFERS_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    TRANSFERS_CHANNEL_ID,
                    "File transfers",
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        // The app plays its own ringtone and call tones, so the channel stays
        // silent. Channel sounds are fixed once created, which is why the
        // sounding channel is replaced rather than updated.
        manager.deleteNotificationChannel(LEGACY_CALL_CHANNEL_ID)
        if (manager.getNotificationChannel(CALL_CHANNEL_ID) == null) {
            manager.createNotificationChannel(
                NotificationChannel(
                    CALL_CHANNEL_ID,
                    "Voice calls",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Incoming and active Conest voice calls"
                    lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                    setSound(null, null)
                    enableVibration(true)
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
        const val ACTION_RESTORE = "dev.conest.action.RESTORE"
        private const val PREFERENCES = "conest_background"
        private const val PREF_ENABLED = "enabled"
        private const val PREF_CALLS_ENABLED = "callsEnabled"

        fun preferences(context: Context) =
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

        /// What the app last asked for, for a start without it.
        fun savePreferences(context: Context, enabled: Boolean, callsEnabled: Boolean) {
            preferences(context).edit()
                .putBoolean(PREF_ENABLED, enabled)
                .putBoolean(PREF_CALLS_ENABLED, callsEnabled)
                .apply()
        }

        fun backgroundWanted(context: Context): Boolean {
            val preferences = preferences(context)
            return preferences.getBoolean(PREF_ENABLED, false) ||
                preferences.getBoolean(PREF_CALLS_ENABLED, false)
        }
        const val ACTION_UPDATE_PREFERENCES = "dev.conest.action.UPDATE_PREFERENCES"
        const val ACTION_END_CALL = "dev.conest.action.END_CALL"
        const val ACTION_START_CALL_AUDIO = "dev.conest.action.START_CALL_AUDIO"
        const val ACTION_STOP_CALL_AUDIO = "dev.conest.action.STOP_CALL_AUDIO"
        const val ACTION_SET_CALL_SPEAKERPHONE =
            "dev.conest.action.SET_CALL_SPEAKERPHONE"
        const val ACTION_UPDATE_TRANSFER = "dev.conest.action.UPDATE_TRANSFER"
        const val ACTION_STOP_TRANSFER = "dev.conest.action.STOP_TRANSFER"
        const val ACTION_NOTIFICATION_WORK = "dev.conest.action.NOTIFICATION_WORK"
        private const val NOTIFICATION_WORK_LIMIT_MS = 120_000L
        private const val NOTIFICATION_WORK_GRACE_MS = 15_000L

        /// Keeps Conest in the foreground while it handles a notification
        /// action (allowed from one: the user just acted on Conest's
        /// notification). False when Android refused.
        fun startNotificationWork(context: Context): Boolean = try {
            val intent = Intent(context, ConestBackgroundService::class.java)
                .setAction(ACTION_NOTIFICATION_WORK)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
            true
        } catch (error: Exception) {
            android.util.Log.w("Conest", "No foreground for a notification action: $error")
            false
        }

        /// Dart handled the notification actions: a little longer for the
        /// sends to leave, then the service goes unless wanted for more.
        fun finishNotificationWork() {
            val service = currentInstance ?: return
            if (!service.notificationWork) return
            service.mainHandler.removeCallbacks(service.endNotificationWork)
            service.mainHandler.postDelayed(
                service.endNotificationWork,
                NOTIFICATION_WORK_GRACE_MS
            )
        }
        const val EXTRA_ENABLED = "enabled"
        const val EXTRA_PERSIST = "persist"
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
        const val EXTRA_CALL_ANSWER = "callAnswer"
        const val EXTRA_CALL_ANSWER_TOKEN = "callAnswerToken"
        const val EXTRA_CALL_AUDIO_TEST = "callAudioTest"
        const val CONTROL_PAUSE_ALL = "pause_all"
        const val CONTROL_RESUME_ALL = "resume_all"
        const val CONTROL_CANCEL_ALL = "cancel_all"
        private const val CALL_CHANNEL_ID = "conest_calls_v2"
        private const val TRANSFERS_CHANNEL_ID = "conest_transfers"
        private const val LEGACY_CALL_CHANNEL_ID = "conest_calls"

        @Volatile
        private var currentInstance: ConestBackgroundService? = null

        fun isRunning(): Boolean = currentInstance != null

        /// Whether [token] is the one of the call ringing now; it works
        /// once.
        fun consumeRingToken(token: String?): Boolean {
            val service = currentInstance ?: return false
            val current = service.ringToken
            if (token.isNullOrEmpty() || current == null || token != current) {
                return false
            }
            service.ringToken = null
            return true
        }

        /// Ends the transfer notice on the running service without a
        /// service intent (refused from the background on Android 8+).
        fun stopTransferDirectly() {
            val service = currentInstance ?: return
            service.transferActive = false
            if (!service.backgroundEnabled && !service.callsEnabled &&
                !service.hasCall() && !service.notificationWork &&
                !service.microphoneTest
            ) {
                service.stopForeground(android.app.Service.STOP_FOREGROUND_REMOVE)
                service.stopSelf()
            } else {
                service.promoteToForeground()
            }
        }

        fun shouldKeepFlutterRuntime(): Boolean {
            val service = currentInstance ?: return false
            return service.backgroundEnabled ||
                service.callsEnabled ||
                service.hasCall() ||
                service.transferActive ||
                service.notificationWork
        }

        // Call audio starts asynchronously through a service intent. These
        // track what Dart last asked for so a close or route change that
        // arrives before the service runs is not lost or misapplied.
        @Volatile
        private var requestedCallAudioHandle = 0L

        @Volatile
        private var requestedSpeakerphone: Boolean? = null

        fun requestVoiceCallMedia(handle: Long) {
            requestedCallAudioHandle = handle
            requestedSpeakerphone = null
        }

        fun setVoiceCallSpeakerphoneEnabled(enabled: Boolean): Boolean {
            val engine = currentInstance?.voiceCallAudio
            if (engine == null && requestedCallAudioHandle == 0L) return false
            requestedSpeakerphone = enabled
            engine?.setSpeakerphoneEnabled(enabled)
            return true
        }

        fun stopVoiceCallMedia() {
            requestedCallAudioHandle = 0L
            requestedSpeakerphone = null
            currentInstance?.stopVoiceCallAudio()
        }
    }
}
