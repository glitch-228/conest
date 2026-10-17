package dev.conest.conest

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun startActivityForResult(intent: Intent, requestCode: Int) {
        FilePickerVisibility.prepare(intent)
        super.startActivityForResult(intent, requestCode)
    }

    private var systemChannel: MethodChannel? = null

    /// What another app shared, copied into the cache, until Dart takes it.
    private var pendingShare: Map<String, Any?>? = null
    private var voiceCallPermissionResult: MethodChannel.Result? = null

    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(ENGINE_CACHE_ID)

    override fun shouldDestroyEngineWithHost(): Boolean =
        !ConestBackgroundService.shouldKeepFlutterRuntime()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        CrashReports.install(this)
        FlutterEngineCache.getInstance().put(ENGINE_CACHE_ID, flutterEngine)
        Thread { clearOldSharedCopies() }.start()
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )
        systemChannel = channel
        activeSystemChannel = channel
        RadioLinkPlugin(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        BitchatBlePlugin(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setBackgroundRuntimeEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    updateBackgroundServicePreferences(
                        enabled,
                        call.argument<Boolean>("callsEnabled") == true,
                    )
                    result.success(null)
                }
                "updateVoiceCallForeground" -> {
                    updateBackgroundServiceState(
                        call.argument<Boolean>("runtimeEnabled") == true,
                        call.argument<Boolean>("callsEnabled") == true,
                        call.argument<String>("peerName"),
                        call.argument<String>("callState") ?: "idle",
                        call.argument<Boolean>("incoming") == true,
                    )
                    result.success(null)
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermissionIfNeeded()
                    result.success(null)
                }
                "requestVoiceCallMicrophonePermission" -> {
                    requestVoiceCallMicrophonePermission(result)
                }
                "requestBluetoothPermissions" -> requestBluetoothPermissions(result)
                "openVoiceCallMedia" -> openVoiceCallMedia(call, result)
                "scheduleScheduledMessageWakeup" -> {
                    val timestampMs = call.argument<Number>("timestampMs")?.toLong()
                    try {
                        scheduleScheduledMessageWakeup(timestampMs)
                        result.success(null)
                    } catch (error: Throwable) {
                        result.error(
                            "scheduled_wakeup_failed",
                            error.message ?: "Could not schedule the background send.",
                            null
                        )
                    }
                }
                "setVoiceCallSpeakerphoneEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    try {
                        if (ConestBackgroundService.setVoiceCallSpeakerphoneEnabled(enabled)) {
                            result.success(enabled)
                        } else {
                            result.error("audio_not_open", "Voice audio is not active.", null)
                        }
                    } catch (error: Throwable) {
                        result.error(
                            "audio_route_failed",
                            error.message ?: "Could not change the voice output.",
                            null
                        )
                    }
                }
                "closeVoiceCallMedia" -> {
                    ConestBackgroundService.stopVoiceCallMedia()
                    result.success(null)
                }
                "updateTransferForeground" -> {
                    val transferred = (call.argument<Number>("transferredBytes"))?.toLong() ?: 0L
                    val total = (call.argument<Number>("totalBytes"))?.toLong() ?: 0L
                    val serviceIntent = Intent(this, ConestBackgroundService::class.java).apply {
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
                    startConestForegroundService(serviceIntent)
                    result.success(null)
                }
                "stopTransferForeground" -> {
                    // Nothing to stop when the service is not running, and
                    // starting a service from the background throws on
                    // Android 8+ (each transfer that ended with the screen
                    // off was recorded as a crash).
                    if (ConestBackgroundService.isRunning()) {
                        try {
                            startService(
                                Intent(this, ConestBackgroundService::class.java).apply {
                                    action = ConestBackgroundService.ACTION_STOP_TRANSFER
                                }
                            )
                        } catch (error: IllegalStateException) {
                            ConestBackgroundService.stopTransferDirectly()
                        }
                    }
                    result.success(null)
                }
                "showMessageNotification" -> {
                    val title = call.argument<String>("title") ?: "Conest"
                    val body = call.argument<String>("body") ?: "New message"
                    val conversationId = call.argument<String>("conversationId") ?: title
                    val senderName = call.argument<String>("senderName") ?: title
                    val selfName = call.argument<String>("selfName") ?: "me"
                    @Suppress("UNCHECKED_CAST")
                    val recent = call.argument<List<Map<String, Any?>>>("recentMessages")
                        ?: emptyList()
                    showMessageNotification(title, body, conversationId, senderName, selfName, recent)
                    result.success(null)
                }
                "dismissMessageNotification" -> {
                    val conversationId = call.argument<String>("conversationId") ?: ""
                    if (conversationId.isNotEmpty()) {
                        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                        manager.cancel(conversationId.hashCode())
                        maybeCancelGroupSummary(manager)
                    }
                    result.success(null)
                }
                "copyImageToClipboard" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val fileName = call.argument<String>("fileName") ?: "conest-image"
                    val mimeType = call.argument<String>("mimeType") ?: "image/jpeg"
                    if (bytes == null) {
                        result.error("missing_bytes", "bytes argument is required.", null)
                    } else {
                        try {
                            val uri = stageClipboardImage(bytes, fileName, mimeType)
                            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            val clip = ClipData.newUri(contentResolver, fileName, uri)
                            cm.setPrimaryClip(clip)
                            result.success(uri.toString())
                        } catch (error: Exception) {
                            result.error(
                                "clipboard_failed",
                                error.message ?: "Could not write image to clipboard.",
                                null
                            )
                        }
                    }
                }
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrEmpty()) {
                        result.error("bad_url", "No URL to open.", null)
                    } else {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            result.success(null)
                        } catch (error: Exception) {
                            result.error(
                                "open_failed",
                                error.message ?: "No browser could open the link.",
                                null
                            )
                        }
                    }
                }
                "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                // `adb shell am start -n dev.conest.conest/.MainActivity
                // --es conestDebugRun routes` asks for the automatic tests;
                // only debug-channel builds act on it (checked in Dart).
                // Read once: a restart or Recents does not run it again.
                "takeExitReports" -> result.success(CrashReports.takeExitReports(this))
                "debugRunRequest" -> {
                    // `--es conestDebugArgs "--debug-run=all --debug-name=…"`
                    // carries a whole lab run, as on a desktop command line.
                    val args = intent?.getStringExtra("conestDebugArgs")
                    val request = intent?.getStringExtra("conestDebugRun")
                    intent?.removeExtra("conestDebugArgs")
                    intent?.removeExtra("conestDebugRun")
                    result.success(if (args != null) "args:$args" else request)
                }
                "showToast" -> {
                    val text = call.argument<String>("text") ?: ""
                    val long = call.argument<Boolean>("long") ?: false
                    if (text.isNotEmpty()) {
                        Toast.makeText(
                            this,
                            text,
                            if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT
                        ).show()
                    }
                    result.success(null)
                }
                "saveMediaToGallery" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val fileName = call.argument<String>("fileName") ?: "conest-attachment"
                    val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                    val kind = call.argument<String>("kind") ?: "other"
                    if (bytes == null) {
                        result.error("missing_bytes", "bytes argument is required.", null)
                    } else {
                        try {
                            val saved = saveMediaToGallery(bytes, fileName, mimeType, kind)
                            result.success(saved)
                        } catch (error: Exception) {
                            result.error(
                                "save_failed",
                                error.message ?: "Could not save the file.",
                                null
                            )
                        }
                    }
                }
                "saveMediaFileToGallery" -> {
                    val sourcePath = call.argument<String>("sourcePath")
                    val fileName = call.argument<String>("fileName") ?: "conest-attachment"
                    val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                    val kind = call.argument<String>("kind") ?: "other"
                    val source = sourcePath?.let(::File)
                    if (source == null || !source.isFile) {
                        result.error("missing_file", "A readable source file is required.", null)
                    } else {
                        try {
                            result.success(saveMediaFileToGallery(source, fileName, mimeType, kind))
                        } catch (error: Exception) {
                            result.error(
                                "save_failed",
                                error.message ?: "Could not save the file.",
                                null
                            )
                        }
                    }
                }
                "installDownloadedApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("missing_path", "APK path is required.", null)
                    } else {
                        try {
                            installDownloadedApk(path)
                            result.success(null)
                        } catch (error: Exception) {
                            result.error(
                                "install_failed",
                                error.message ?: "Could not open the Android installer.",
                                null
                            )
                        }
                    }
                }
                "takeClipboardMedia" -> {
                    val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    val uri = cm.primaryClip?.let { clip ->
                        (0 until clip.itemCount).firstNotNullOfOrNull { clip.getItemAt(it).uri }
                    }
                    if (uri == null) {
                        result.success(null)
                    } else {
                        Thread {
                            val copied = copySharedUri(uri, File(cacheDir, "pasted/${System.currentTimeMillis()}"), 0)
                            runOnUiThread { result.success(copied) }
                        }.start()
                    }
                }
                "takePendingShare" -> {
                    result.success(pendingShare)
                    pendingShare = null
                }
                "powerState" -> result.success(powerState())
                else -> result.notImplemented()
            }
        }
        dispatchTransferControl(intent)
        dispatchShare(intent)
    }

    /** Battery, charging and battery saver, for how many routes messages use. */
    private fun powerState(): Map<String, Any?> {
        val battery = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val present = battery?.getBooleanExtra(BatteryManager.EXTRA_PRESENT, true) ?: true
        val plugged = battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1) ?: -1
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "hasBattery" to present,
            "charging" to if (battery == null) null else plugged > 0,
            "batteryPercent" to if (level >= 0 && scale > 0) level * 100 / scale else null,
            "batterySaver" to power.isPowerSaveMode,
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        dispatchTransferControl(intent)
        dispatchShare(intent)
    }

    /// Copies what another app shared (files, images, text) into the cache
    /// off the main thread, then tells Dart to take it.
    private fun dispatchShare(intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return
        }
        // Handled once, also after a rotation re-delivers the intent.
        intent.action = null
        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_SEND) {
            @Suppress("DEPRECATION")
            (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let { uris.add(it) }
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        }
        val clip = intent.clipData
        if (uris.isEmpty() && clip != null) {
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index).uri?.let { uris.add(it) }
            }
        }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        Thread {
            val folder = File(cacheDir, "shared/${System.currentTimeMillis()}")
            folder.mkdirs()
            val files = mutableListOf<Map<String, Any?>>()
            val budget = longArrayOf(MAX_SHARED_TOTAL_BYTES)
            for ((index, uri) in uris.take(MAX_SHARED_FILES).withIndex()) {
                // An item that cannot be read is left out; the rest still go.
                copySharedUri(uri, folder, index, budget)?.let { files.add(it) }
            }
            runOnUiThread {
                if (files.isEmpty() && text.isNullOrEmpty()) return@runOnUiThread
                pendingShare = mapOf("files" to files, "text" to text)
                systemChannel?.invokeMethod("shareAvailable", null)
            }
        }.start()
    }

    /// Shared and pasted copies older than a day were staged long ago (or
    /// never): they go.
    private fun clearOldSharedCopies() {
        val cutoff = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        for (name in listOf("shared", "pasted")) {
            File(cacheDir, name).listFiles()?.forEach { entry ->
                if (entry.lastModified() < cutoff) entry.deleteRecursively()
            }
        }
    }

    /// Copies [uri] (another app's content) into [folder]: its path, name
    /// and type, or null when it cannot be read.
    private fun copySharedUri(
        uri: Uri,
        folder: File,
        index: Int,
        budget: LongArray = longArrayOf(MAX_SHARED_FILE_BYTES),
    ): Map<String, Any?>? {
        // Only other apps' content: a file:// path or our own provider would
        // read Conest's private files with Conest's permissions.
        if (uri.scheme != "content") return null
        val authority = uri.authority ?: return null
        if (authority == packageName || authority.startsWith("$packageName.")) return null
        return try {
            folder.mkdirs()
            var name = "shared-$index"
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getString(0)?.let { name = it }
                }
            }
            val safe = name.replace(Regex("[/\\\\:*?\"<>|\\u0000]"), "_")
                .take(120).ifBlank { "shared-$index" }
            val target = File(folder, "$index-$safe")
            val limit = minOf(budget[0], MAX_SHARED_FILE_BYTES)
            val copied = contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > limit) {
                            throw java.io.IOException("Shared item too large")
                        }
                        output.write(buffer, 0, read)
                    }
                    total
                }
            }
            if (copied != null) budget[0] -= copied
            if (copied == null) {
                null
            } else {
                mapOf(
                    "path" to target.absolutePath,
                    "name" to safe,
                    "mimeType" to (contentResolver.getType(uri) ?: "application/octet-stream"),
                )
            }
        } catch (error: Exception) {
            // A partial copy (too large, unreadable) is not left behind.
            folder.listFiles()?.filter { it.name.startsWith("$index-") }?.forEach { it.delete() }
            null
        }
    }

    private fun dispatchTransferControl(intent: Intent?) {
        val action = intent?.getStringExtra(ConestBackgroundService.EXTRA_TRANSFER_CONTROL)
            ?: return
        intent.removeExtra(ConestBackgroundService.EXTRA_TRANSFER_CONTROL)
        systemChannel?.invokeMethod("transferControl", mapOf("action" to action))
    }

    private fun updateBackgroundServiceState(
        runtimeEnabled: Boolean,
        callsEnabled: Boolean,
        peerName: String?,
        callState: String,
        incoming: Boolean,
    ) {
        val intent = Intent(this, ConestBackgroundService::class.java).apply {
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
            startConestForegroundService(intent)
        } else {
            try {
                startService(intent)
            } catch (error: IllegalStateException) {
                // In the background with nothing to run: nothing to update.
            }
        }
    }

    private fun updateBackgroundServicePreferences(
        runtimeEnabled: Boolean,
        callsEnabled: Boolean,
    ) {
        val intent = Intent(this, ConestBackgroundService::class.java).apply {
            action = ConestBackgroundService.ACTION_UPDATE_PREFERENCES
            putExtra(ConestBackgroundService.EXTRA_ENABLED, runtimeEnabled)
            putExtra(ConestBackgroundService.EXTRA_CALLS_ENABLED, callsEnabled)
        }
        if (runtimeEnabled || callsEnabled) {
            startConestForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun startConestForegroundService(intent: Intent) {
        ensureNotificationChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST
            )
        }
    }

    private fun requestVoiceCallMicrophonePermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (voiceCallPermissionResult != null) {
            result.error(
                "permission_pending",
                "Microphone permission is already being requested.",
                null
            )
            return
        }
        voiceCallPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.RECORD_AUDIO),
            VOICE_CALL_PERMISSION_REQUEST
        )
    }

    private var bluetoothPermissionResult: MethodChannel.Result? = null

    /** Android 12+ asks for nearby-device access before scanning or connecting. */
    private fun requestBluetoothPermissions(result: MethodChannel.Result) {
        val needed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_ADVERTISE,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (needed.isEmpty()) {
            result.success(true)
            return
        }
        if (bluetoothPermissionResult != null) {
            result.error("permission_pending", "Bluetooth permission is already being requested.", null)
            return
        }
        bluetoothPermissionResult = result
        requestPermissions(needed.toTypedArray(), BLUETOOTH_PERMISSION_REQUEST)
    }

    @Deprecated("Deprecated in Android, retained for permission callbacks.")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == BLUETOOTH_PERMISSION_REQUEST) {
            val result = bluetoothPermissionResult
            bluetoothPermissionResult = null
            result?.success(
                grantResults.isNotEmpty() &&
                    grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            )
        }
        if (requestCode == VOICE_CALL_PERMISSION_REQUEST) {
            val result = voiceCallPermissionResult
            voiceCallPermissionResult = null
            result?.success(
                grantResults.isNotEmpty() &&
                    grantResults[0] == PackageManager.PERMISSION_GRANTED
            )
        }
    }

    private fun openVoiceCallMedia(
        call: MethodCall,
        result: MethodChannel.Result
    ) {
        val handle = (call.argument<Number>("handle"))?.toLong()
        if (handle == null || handle == 0L) {
            result.error("missing_audio_handle", "Native voice audio handle is missing.", null)
            return
        }
        try {
            ConestBackgroundService.requestVoiceCallMedia(handle)
            startConestForegroundService(
                Intent(this, ConestBackgroundService::class.java).apply {
                    action = ConestBackgroundService.ACTION_START_CALL_AUDIO
                    putExtra(ConestBackgroundService.EXTRA_CALL_AUDIO_HANDLE, handle)
                }
            )
            result.success(true)
        } catch (error: Throwable) {
            ConestBackgroundService.stopVoiceCallMedia()
            result.error(
                "audio_start_failed",
                error.message ?: "Could not start Android voice audio.",
                null
            )
        }
    }

    override fun onDestroy() {
        val keepRuntime = ConestBackgroundService.shouldKeepFlutterRuntime()
        if (!keepRuntime) {
            FlutterEngineCache.getInstance().remove(ENGINE_CACHE_ID)
            if (activeSystemChannel === systemChannel) activeSystemChannel = null
        }
        super.onDestroy()
    }

    private fun scheduleScheduledMessageWakeup(timestampMs: Long?) {
        val alarmManager = getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
        val intent = Intent(this, ScheduledMessageWakeupReceiver::class.java).apply {
            action = ScheduledMessageWakeupReceiver.ACTION_SCHEDULED_MESSAGE_DUE
        }
        val pendingIntent = PendingIntent.getBroadcast(
            this,
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

    private fun showMessageNotification(
        title: String,
        body: String,
        conversationId: String,
        senderName: String,
        selfName: String,
        recentMessages: List<Map<String, Any?>>
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureNotificationChannel()
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("conversationId", conversationId)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            conversationId.hashCode(),
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = notificationBuilder(MESSAGES_CHANNEL_ID)
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
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(conversationId.hashCode(), builder.build())
        postOrRefreshGroupSummary(manager)
    }

    private fun postOrRefreshGroupSummary(manager: NotificationManager) {
        val summary = notificationBuilder(MESSAGES_CHANNEL_ID)
            .setContentTitle("Conest")
            .setContentText("New messages")
            .setGroup(GROUP_KEY_MESSAGES)
            .setGroupSummary(true)
            .setAutoCancel(true)
            .build()
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

    private fun saveMediaToGallery(
        bytes: ByteArray,
        fileName: String,
        mimeType: String,
        kind: String
    ): String {
        val safeName = sanitizeAttachmentFileName(fileName)
        val resolvedKind = when {
            kind == "image" || mimeType.startsWith("image/") -> "image"
            kind == "video" || mimeType.startsWith("video/") -> "video"
            else -> "other"
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val (collection, relativePath) = when (resolvedKind) {
                "image" -> Pair(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    "${Environment.DIRECTORY_PICTURES}/conest"
                )
                "video" -> Pair(
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                    "${Environment.DIRECTORY_MOVIES}/conest"
                )
                else -> Pair(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    "${Environment.DIRECTORY_DOWNLOADS}/conest"
                )
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = applicationContext.contentResolver
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("MediaStore.insert returned null")
            try {
                resolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: throw IllegalStateException("openOutputStream returned null")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                return uri.toString()
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
        }
        // Pre-Q: write directly to the public directory (requires
        // WRITE_EXTERNAL_STORAGE which the manifest declares for API ≤ 28).
        val baseDirName = when (resolvedKind) {
            "image" -> Environment.DIRECTORY_PICTURES
            "video" -> Environment.DIRECTORY_MOVIES
            else -> Environment.DIRECTORY_DOWNLOADS
        }
        val baseDir = Environment.getExternalStoragePublicDirectory(baseDirName)
        val subDir = java.io.File(baseDir, "conest")
        if (!subDir.exists() && !subDir.mkdirs()) {
            throw IllegalStateException("Could not create ${subDir.path}")
        }
        var target = java.io.File(subDir, safeName)
        var suffix = 1
        val stem = target.nameWithoutExtension.ifBlank { "conest-attachment" }
        val extension = target.extension.let { if (it.isEmpty()) "" else ".$it" }
        while (target.exists()) {
            target = File(subDir, "$stem ($suffix)$extension")
            suffix++
        }
        target.writeBytes(bytes)
        return target.absolutePath
    }

    private fun saveMediaFileToGallery(
        source: File,
        fileName: String,
        mimeType: String,
        kind: String
    ): String {
        val safeName = sanitizeAttachmentFileName(fileName)
        val resolvedKind = when {
            kind == "image" || mimeType.startsWith("image/") -> "image"
            kind == "video" || mimeType.startsWith("video/") -> "video"
            else -> "other"
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val (collection, relativePath) = when (resolvedKind) {
                "image" -> Pair(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    "${Environment.DIRECTORY_PICTURES}/conest"
                )
                "video" -> Pair(
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                    "${Environment.DIRECTORY_MOVIES}/conest"
                )
                else -> Pair(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                    "${Environment.DIRECTORY_DOWNLOADS}/conest"
                )
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = applicationContext.contentResolver
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("MediaStore.insert returned null")
            try {
                resolver.openOutputStream(uri)?.use { output ->
                    source.inputStream().use { input -> input.copyTo(output, 1024 * 1024) }
                } ?: throw IllegalStateException("openOutputStream returned null")
                values.clear()
                values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                return uri.toString()
            } catch (error: Exception) {
                resolver.delete(uri, null, null)
                throw error
            }
        }
        val baseDirName = when (resolvedKind) {
            "image" -> Environment.DIRECTORY_PICTURES
            "video" -> Environment.DIRECTORY_MOVIES
            else -> Environment.DIRECTORY_DOWNLOADS
        }
        val subDir = File(
            Environment.getExternalStoragePublicDirectory(baseDirName),
            "conest"
        )
        if (!subDir.exists() && !subDir.mkdirs()) {
            throw IllegalStateException("Could not create ${subDir.path}")
        }
        var target = File(subDir, safeName)
        var suffix = 1
        val stem = target.nameWithoutExtension.ifBlank { "conest-attachment" }
        val extension = target.extension.let { if (it.isEmpty()) "" else ".$it" }
        while (target.exists()) {
            target = File(subDir, "$stem ($suffix)$extension")
            suffix++
        }
        source.inputStream().use { input ->
            target.outputStream().use { output -> input.copyTo(output, 1024 * 1024) }
        }
        return target.absolutePath
    }

    private fun stageClipboardImage(
        bytes: ByteArray,
        fileName: String,
        mimeType: String
    ): android.net.Uri {
        val cacheDir = java.io.File(applicationContext.cacheDir, "clipboard")
        if (!cacheDir.exists() && !cacheDir.mkdirs()) {
            throw IllegalStateException("Could not create ${cacheDir.path}")
        }
        val safeName = sanitizeAttachmentFileName(fileName)
        val ext = when (mimeType.lowercase()) {
            "image/png" -> ".png"
            "image/gif" -> ".gif"
            "image/webp" -> ".webp"
            else -> if (safeName.contains('.')) "" else ".jpg"
        }
        val target = java.io.File(
            cacheDir,
            if (ext.isEmpty()) safeName else "$safeName$ext"
        )
        target.writeBytes(bytes)
        return FileProvider.getUriForFile(
            this,
            "${packageName}.fileprovider",
            target
        )
    }

    private fun sanitizeAttachmentFileName(input: String): String {
        var value = input
            .map { char ->
                when {
                    char == '/' || char == '\\' -> '_'
                    char.code < 0x20 || char.code == 0x7f -> null
                    char.code in 0x202a..0x202e || char.code in 0x2066..0x2069 -> null
                    char in charArrayOf('<', '>', ':', '"', '|', '?', '*') -> '_'
                    else -> char
                }
            }
            .filterNotNull()
            .joinToString("")
            .trim()
            .trimStart('.', ' ')
            .trimEnd('.', ' ')
        if (value.isBlank() || value == "." || value == "..") {
            value = "conest-attachment"
        }
        val stem = value.substringBeforeLast('.', value).lowercase()
        val reserved = setOf(
            "con", "prn", "aux", "nul",
            "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
            "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"
        )
        if (stem in reserved) value = "_$value"
        if (value.length > 120) {
            val extension = value.substringAfterLast('.', "").let {
                if (it.isEmpty() || it.length > 19) "" else ".$it"
            }
            value = value.take(120 - extension.length) + extension
        }
        return value
    }

    private fun installDownloadedApk(path: String) {
        val apkFile = File(path)
        require(apkFile.exists()) { "Downloaded APK is missing: $path" }
        val uri: Uri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            apkFile
        )
        val installIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(installIntent)
    }

    private fun notificationBuilder(channelId: String): Notification.Builder {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_conest)
            .setColor(0xFF04F6AF.toInt())
            .setPriority(Notification.PRIORITY_DEFAULT)
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
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
    }

    companion object {
        private const val MAX_SHARED_FILES = 50
        private const val MAX_SHARED_FILE_BYTES = 2L * 1024 * 1024 * 1024
        private const val MAX_SHARED_TOTAL_BYTES = 4L * 1024 * 1024 * 1024
        @Volatile
        private var activeSystemChannel: MethodChannel? = null

        private const val ENGINE_CACHE_ID = "conest_main_engine"

        @JvmStatic
        fun reportVoiceCallAudioFailure(reason: String) {
            try {
                activeSystemChannel?.invokeMethod(
                    "voiceCallAudioFailure",
                    mapOf("reason" to reason),
                )
            } catch (_: RuntimeException) {
                // The Flutter engine may already be shutting down.
            }
        }

        fun requestScheduledMessagePump() {
            try {
                activeSystemChannel?.invokeMethod("scheduledMessageDue", null)
            } catch (_: RuntimeException) {
                // If the activity engine is going away, the next foreground
                // startup still dispatches every overdue persisted item.
            }
        }

        private const val CHANNEL = "dev.conest.conest/system"
        private const val MESSAGES_CHANNEL_ID = "conest_messages"
        const val BACKGROUND_CHANNEL_ID = "conest_background"
        private const val NOTIFICATION_PERMISSION_REQUEST = 6017
        private const val VOICE_CALL_PERMISSION_REQUEST = 6018
        private const val SCHEDULED_MESSAGE_WAKEUP_REQUEST = 6019
        private const val BLUETOOTH_PERMISSION_REQUEST = 6020
        private const val GROUP_KEY_MESSAGES = "dev.conest.conest.messages"
        private const val SUMMARY_NOTIFICATION_ID = 0x100b1ade
    }
}
