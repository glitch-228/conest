package dev.conest.conest

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.Collections
import java.util.WeakHashMap

/// The one Flutter engine: made by the activity when it opens first, or
/// here, without a screen, when the background service starts on its own
/// (the process killed and restarted, a reboot, an update). The activity
/// then shows that same engine.
object ConestEngine {
    const val CACHE_ID = "conest_main_engine"

    /// The engine's system channel, for messages to Dart (a scheduled
    /// message due, call audio failing) with or without a screen.
    @Volatile
    var systemChannel: MethodChannel? = null

    private val pluginsAttached: MutableSet<FlutterEngine> =
        Collections.newSetFromMap(WeakHashMap())

    fun cached(): FlutterEngine? = FlutterEngineCache.getInstance().get(CACHE_ID)

    /// The running engine, started headless if there is none.
    @Synchronized
    fun ensureRunning(context: Context): FlutterEngine {
        cached()?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        attachPlugins(app, engine)
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, ConestSystem.CHANNEL)
        channel.setMethodCallHandler(headlessHandler(app))
        systemChannel = channel
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        FlutterEngineCache.getInstance().put(CACHE_ID, engine)
        return engine
    }

    /// Conest's own plugins, once per engine (the activity may open on an
    /// engine the service started).
    @Synchronized
    fun attachPlugins(context: Context, engine: FlutterEngine) {
        if (!pluginsAttached.add(engine)) return
        val messenger = engine.dartExecutor.binaryMessenger
        RadioLinkPlugin(context.applicationContext, messenger)
        BitchatBlePlugin(context.applicationContext, messenger)
    }

    /// The system channel without a screen: what needs no activity.
    fun headlessHandler(context: Context): MethodChannel.MethodCallHandler =
        MethodChannel.MethodCallHandler { call, result ->
            if (!ConestSystem.handle(context, call, result)) {
                result.notImplemented()
            }
        }
}
