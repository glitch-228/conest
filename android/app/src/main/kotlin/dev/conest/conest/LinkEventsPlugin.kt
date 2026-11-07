package dev.conest.conest

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Tells Dart when the network links may have changed, for cable and USB
 * tethering links: Android has no interface monitor for apps.
 *
 * Events on [EVENTS]: {source: "network" | "usb" | "tether"}.
 *  - "network": a [ConnectivityManager.NetworkCallback] for every network.
 *    It fires at once for the networks that are already there, and USB
 *    tethering with this phone as the host raises none.
 *  - "usb": the `USB_STATE` broadcast (extras connected, rndis, ncm).
 *  - "tether": the `TETHER_STATE_CHANGED` broadcast.
 * Neither broadcast is documented API and either may be restricted or gone on
 * a newer Android: both are registered in a try block, and the Dart side
 * keeps a bounded fallback until one of them is seen to work. The initial
 * sticky delivery at registration is not passed on.
 *
 * Methods on [METHODS]: openTetherSettings (apps cannot turn tethering on;
 * this opens the system page for it).
 *
 * Registered only while Dart listens (while Conest runs).
 */
class LinkEventsPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        const val METHODS = "dev.conest/links"
        const val EVENTS = "dev.conest/links/events"
        private const val USB_STATE = "android.hardware.usb.action.USB_STATE"
        private const val TETHER_STATE = "android.net.conn.TETHER_STATE_CHANGED"
        private const val TETHER_SETTINGS = "android.settings.TETHER_SETTINGS"
    }

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var receiver: BroadcastReceiver? = null

    init {
        MethodChannel(messenger, METHODS).setMethodCallHandler(this)
        EventChannel(messenger, EVENTS).setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openTetherSettings" -> result.success(openTetherSettings())
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        register()
    }

    override fun onCancel(arguments: Any?) {
        unregister()
        sink = null
    }

    private fun emit(source: String) {
        main.post { sink?.success(mapOf("source" to source)) }
    }

    private fun register() {
        val manager =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (manager != null && networkCallback == null) {
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = emit("network")
                override fun onLost(network: Network) = emit("network")
                override fun onLinkPropertiesChanged(
                    network: Network,
                    linkProperties: LinkProperties,
                ) = emit("network")
            }
            try {
                manager.registerNetworkCallback(NetworkRequest.Builder().build(), callback)
                networkCallback = callback
            } catch (_: Exception) {
                // No network state access: the broadcasts and the Dart
                // fallback remain.
            }
        }
        if (receiver == null) {
            val filter = IntentFilter().apply {
                addAction(USB_STATE)
                addAction(TETHER_STATE)
            }
            val created = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    // What was sticky when the receiver was registered is the
                    // state at the start, not a change.
                    if (isInitialStickyBroadcast) return
                    emit(if (intent.action == TETHER_STATE) "tether" else "usb")
                }
            }
            try {
                if (Build.VERSION.SDK_INT >= 33) {
                    context.registerReceiver(created, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    @Suppress("UnspecifiedRegisterReceiverFlag")
                    context.registerReceiver(created, filter)
                }
                receiver = created
            } catch (_: Exception) {
                // Restricted on this Android: the Dart fallback covers it.
            }
        }
    }

    private fun unregister() {
        val manager =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        networkCallback?.let {
            try {
                manager?.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        networkCallback = null
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: Exception) {
            }
        }
        receiver = null
    }

    private fun openTetherSettings(): Boolean {
        for (action in listOf(TETHER_SETTINGS, Settings.ACTION_WIRELESS_SETTINGS)) {
            try {
                context.startActivity(
                    Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                return true
            } catch (_: Exception) {
                // The next page: some makers do not export the tethering one.
            }
        }
        return false
    }
}
