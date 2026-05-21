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
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.widget.Toast
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setBackgroundRuntimeEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    setBackgroundRuntimeEnabled(enabled)
                    result.success(null)
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermissionIfNeeded()
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
                else -> result.notImplemented()
            }
        }
    }

    private fun setBackgroundRuntimeEnabled(enabled: Boolean) {
        val intent = Intent(this, ConestBackgroundService::class.java)
        if (enabled) {
            ensureNotificationChannel()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } else {
            stopService(intent)
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
        val safeName = if (fileName.isBlank()) "conest-attachment" else fileName
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
        val target = java.io.File(subDir, safeName)
        target.writeBytes(bytes)
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
        // Strip any path components the caller might have passed.
        val safeName = fileName.substringAfterLast('/').ifBlank { "conest-image" }
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
            .setSmallIcon(applicationInfo.icon)
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
        private const val CHANNEL = "dev.conest.conest/system"
        private const val MESSAGES_CHANNEL_ID = "conest_messages"
        const val BACKGROUND_CHANNEL_ID = "conest_background"
        private const val NOTIFICATION_PERMISSION_REQUEST = 6017
        private const val GROUP_KEY_MESSAGES = "dev.conest.conest.messages"
        private const val SUMMARY_NOTIFICATION_ID = 0x100b1ade
    }
}
