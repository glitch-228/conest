package dev.conest.conest

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.ArrayDeque
import java.util.UUID

/**
 * The bitchat Bluetooth mesh transport: Conest acts as both a peripheral
 * (GATT server with bitchat's service, advertised) and a central (scans
 * for that service, connects, subscribes). Every neighbour is a link that
 * carries whole bitchat packets; the mesh logic runs in Dart.
 *
 * Methods on [METHODS]: start, stop, broadcast {bytes, except} (answers how
 * many neighbours got the packet). Events on [EVENTS]: {link, data} for
 * received packets, {link, up} when a neighbour comes or goes and
 * {problem} when Bluetooth is off or refuses something (null once it works
 * again).
 * All state lives on the main thread.
 *
 * Links only carry packets once both sides can take a whole 512-byte
 * packet in one write or notification (ATT MTU of at least 515), because
 * bitchat treats every write as a complete packet.
 */
class BitchatBlePlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        const val METHODS = "dev.conest/bitchat"
        const val EVENTS = "dev.conest/bitchat/events"
        private val SERVICE: UUID = UUID.fromString("F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
        private val CHARACTERISTIC: UUID = UUID.fromString("A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val MAX_CLIENT_LINKS = 6
        private const val MAX_SERVER_LINKS = 8
        private const val MAX_PACKET = 512
        private const val MIN_MTU = MAX_PACKET + 3
        private const val MAX_QUEUED_PER_LINK = 64
        private const val MAX_ATTEMPTS = 5
        private const val NOTIFY_WATCHDOG_MS = 2_000L
        private const val CLIENT_SETUP_MS = 15_000L
        private const val MAX_INBOUND_PER_SECOND = 40
        private const val WRITE_WATCHDOG_MS = 5_000L

        /** A link silent this long may make room for a new neighbour. */
        private const val IDLE_LINK_MS = 120_000L
        private var current: BitchatBlePlugin? = null
    }

    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null

    /** Dart asked for the mesh; it comes back after Bluetooth turns on. */
    private var wanted = false
    private var active = false
    private var server: BluetoothGattServer? = null
    private var serverCharacteristic: BluetoothGattCharacteristic? = null
    private val servers = LinkedHashMap<String, ServerLink>()
    private val serverMtu = HashMap<String, Int>()
    private val preparedWrites = HashMap<String, ByteArrayOutputStream>()
    private var notifying: ServerLink? = null
    private var notifyToken = 0
    private val clients = LinkedHashMap<String, ClientLink>()
    private val backoff = HashMap<String, Pair<Long, Long>>()
    private val inbound = HashMap<String, Pair<Long, Int>>()
    private val lastHeard = HashMap<String, Long>()
    private var stateReceiver: BroadcastReceiver? = null

    private class Outgoing(val bytes: ByteArray) {
        var attempts = 0
    }

    private inner class ServerLink(val device: BluetoothDevice) {
        val queue = ArrayDeque<Outgoing>()
        val since = SystemClock.elapsedRealtime()
    }

    private inner class ClientLink(val address: String) {
        var gatt: BluetoothGatt? = null
        var characteristic: BluetoothGattCharacteristic? = null
        val writes = ArrayDeque<Outgoing>()
        var writing = false
        var writeToken = 0
        var ready = false
        var since = SystemClock.elapsedRealtime()
    }

    init {
        current?.shutdown()
        current = this
        MethodChannel(messenger, METHODS).setMethodCallHandler(this)
        EventChannel(messenger, EVENTS).setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { events?.success(event) }
    }

    private fun problem(text: String?) = emit(mapOf("problem" to text))

    /** Whether [link] has been silent long enough to give up its slot. */
    private fun idle(link: String, since: Long): Boolean =
        SystemClock.elapsedRealtime() - (lastHeard[link] ?: since) > IDLE_LINK_MS

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    val adapter = manager.adapter ?: throw IllegalStateException("Bluetooth is missing.")
                    wanted = true
                    watchAdapter()
                    if (adapter.isEnabled) {
                        try {
                            startAll()
                        } catch (error: Throwable) {
                            shutdown()
                            throw error
                        }
                    } else {
                        // Starts by itself once Bluetooth is turned on.
                        problem("Bluetooth is off.")
                    }
                    result.success(null)
                }
                "stop" -> {
                    shutdown()
                    result.success(null)
                }
                "broadcast" -> result.success(
                    broadcast(
                        call.argument<ByteArray>("bytes") ?: ByteArray(0),
                        call.argument<String>("except"),
                    ),
                )
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error("bitchat", error.message ?: error.toString(), null)
        }
    }

    private val manager: BluetoothManager
        get() = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager

    /** Restarts the mesh when Bluetooth comes back on, and tears it down when it goes off. */
    private fun watchAdapter() {
        if (stateReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context, intent: Intent) {
                when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                    BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> {
                        stopAll()
                        if (wanted) problem("Bluetooth is off.")
                    }
                    BluetoothAdapter.STATE_ON -> if (wanted) {
                        try {
                            startAll()
                            problem(null)
                        } catch (error: Throwable) {
                            problem(error.message ?: error.toString())
                        }
                    }
                }
            }
        }
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        stateReceiver = receiver
    }

    private fun shutdown() {
        wanted = false
        stateReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: Throwable) {
            }
        }
        stateReceiver = null
        stopAll()
    }

    @SuppressLint("MissingPermission")
    private fun startAll() {
        if (active) return
        val adapter = manager.adapter ?: throw IllegalStateException("Bluetooth is missing.")
        if (!adapter.isEnabled) throw IllegalStateException("Bluetooth is off.")
        try {
            // Peripheral: bitchat's service with one characteristic.
            val characteristic = BluetoothGattCharacteristic(
                CHARACTERISTIC,
                BluetoothGattCharacteristic.PROPERTY_READ or
                    BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                    BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                BluetoothGattCharacteristic.PERMISSION_READ or
                    BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
            characteristic.addDescriptor(
                BluetoothGattDescriptor(
                    CCCD,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
                ),
            )
            val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            service.addCharacteristic(characteristic)
            serverCharacteristic = characteristic
            server = (manager.openGattServer(context, serverCallback)
                ?: throw IllegalStateException("Bluetooth refused the GATT server."))
                .also { it.addService(service) }
            advertise()
            // Central: find and join neighbours.
            (adapter.bluetoothLeScanner ?: throw IllegalStateException("Bluetooth scanning is unavailable."))
                .startScan(
                    listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()),
                    ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build(),
                    scanCallback,
                )
            active = true
        } catch (error: Throwable) {
            active = true
            stopAll()
            throw error
        }
    }

    @SuppressLint("MissingPermission")
    private fun advertise() {
        manager.adapter?.bluetoothLeAdvertiser?.startAdvertising(
            AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(true)
                .build(),
            AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).build(),
            advertiseCallback,
        ) ?: throw IllegalStateException("Bluetooth advertising is unavailable.")
    }

    @SuppressLint("MissingPermission")
    private fun stopAll() {
        if (!active) return
        active = false
        val adapter = manager.adapter
        try {
            adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (_: Throwable) {
        }
        try {
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Throwable) {
        }
        for (link in clients.values.toList()) {
            try {
                link.gatt?.disconnect()
                link.gatt?.close()
            } catch (_: Throwable) {
            }
            emit(mapOf("link" to "c:${link.address}", "up" to false))
        }
        clients.clear()
        for (address in servers.keys) {
            emit(mapOf("link" to "s:$address", "up" to false))
        }
        try {
            server?.close()
        } catch (_: Throwable) {
        }
        server = null
        servers.clear()
        serverMtu.clear()
        preparedWrites.clear()
        inbound.clear()
        lastHeard.clear()
        notifying = null
        notifyToken++
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            if (errorCode == AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED) return
            problem("Bluetooth advertising failed ($errorCode).")
            // Try again later: others still find this phone once it works.
            main.postDelayed({
                if (active) {
                    try {
                        advertise()
                    } catch (_: Throwable) {
                    }
                }
            }, 30_000L)
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post { connectTo(result.device) }
        }

        override fun onScanFailed(errorCode: Int) {
            problem("Bluetooth scanning failed ($errorCode).")
        }
    }

    /** Waits longer before reconnecting to a device that keeps failing. */
    private fun noteFailure(address: String) {
        val previous = backoff[address]?.second ?: 0L
        val delay = if (previous == 0L) 30_000L else minOf(previous * 2, 300_000L)
        backoff[address] = (SystemClock.elapsedRealtime() + delay) to delay
    }

    @SuppressLint("MissingPermission")
    private fun connectTo(device: BluetoothDevice) {
        val address = device.address
        if (!active || clients.containsKey(address) || servers.containsKey(address)) return
        val until = backoff[address]?.first
        if (until != null && SystemClock.elapsedRealtime() < until) return
        if (clients.size >= MAX_CLIENT_LINKS) {
            // Make room only by dropping a neighbour that has gone quiet, so
            // devices that connect and say nothing cannot hold every slot.
            val quiet = clients.values
                .filter { it.ready && idle("c:${it.address}", it.since) }
                .minByOrNull { lastHeard["c:${it.address}"] ?: it.since }
                ?: return
            dropClient(quiet, failed = true)
        }
        val link = ClientLink(address)
        clients[address] = link
        link.gatt = device.connectGatt(context, false, clientCallback(link), BluetoothDevice.TRANSPORT_LE)
        if (link.gatt == null) {
            clients.remove(address)
            noteFailure(address)
            return
        }
        main.postDelayed({
            if (clients[address] === link && !link.ready) dropClient(link, failed = true)
        }, CLIENT_SETUP_MS)
    }

    @SuppressLint("MissingPermission")
    private fun clientCallback(link: ClientLink) = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, state: Int) {
            main.post {
                if (state == BluetoothProfile.STATE_CONNECTED && active) {
                    if (!gatt.requestMtu(517)) dropClient(link, failed = true)
                } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                    dropClient(link, failed = !link.ready)
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            main.post {
                // A smaller MTU would split packets bitchat reads whole.
                if (status != BluetoothGatt.GATT_SUCCESS || mtu < MIN_MTU) {
                    dropClient(link, failed = true)
                } else if (!gatt.discoverServices()) {
                    dropClient(link, failed = true)
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            main.post {
                val characteristic = gatt.getService(SERVICE)?.getCharacteristic(CHARACTERISTIC)
                if (status != BluetoothGatt.GATT_SUCCESS || characteristic == null) {
                    dropClient(link, failed = true)
                    return@post
                }
                link.characteristic = characteristic
                gatt.setCharacteristicNotification(characteristic, true)
                val descriptor = characteristic.getDescriptor(CCCD)
                if (descriptor != null) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                    } else {
                        @Suppress("DEPRECATION")
                        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        @Suppress("DEPRECATION")
                        gatt.writeDescriptor(descriptor)
                    }
                } else {
                    linkUp(link)
                }
            }
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            main.post {
                if (status == BluetoothGatt.GATT_SUCCESS) linkUp(link) else dropClient(link, failed = true)
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            main.post {
                link.writing = false
                pumpClient(link)
            }
        }

        @Deprecated("Deprecated in API 33")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            val value = characteristic.value ?: return
            deliver("c:${link.address}", value.copyOf())
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            deliver("c:${link.address}", value)
        }
    }

    /** Passes a packet to Dart unless the link floods. Runs on any thread. */
    private fun deliver(link: String, value: ByteArray) {
        if (value.isEmpty() || value.size > 4096) return
        main.post {
            val second = SystemClock.elapsedRealtime() / 1000
            val (window, count) = inbound[link] ?: (second to 0)
            val next = if (window == second) count + 1 else 1
            inbound[link] = second to next
            lastHeard[link] = SystemClock.elapsedRealtime()
            if (next <= MAX_INBOUND_PER_SECOND) {
                events?.success(mapOf("link" to link, "data" to value))
            }
        }
    }

    private fun linkUp(link: ClientLink) {
        if (link.ready || clients[link.address] !== link) return
        link.ready = true
        link.since = SystemClock.elapsedRealtime()
        backoff.remove(link.address)
        emit(mapOf("link" to "c:${link.address}", "up" to true))
        pumpClient(link)
    }

    @SuppressLint("MissingPermission")
    private fun dropClient(link: ClientLink, failed: Boolean = false) {
        if (clients[link.address] !== link) return
        clients.remove(link.address)
        if (failed) noteFailure(link.address)
        try {
            link.gatt?.disconnect()
            link.gatt?.close()
        } catch (_: Throwable) {
        }
        inbound.remove("c:${link.address}")
        lastHeard.remove("c:${link.address}")
        if (link.ready) emit(mapOf("link" to "c:${link.address}", "up" to false))
    }

    @SuppressLint("MissingPermission")
    private fun pumpClient(link: ClientLink) {
        if (link.writing || !link.ready || clients[link.address] !== link) return
        val gatt = link.gatt ?: return
        val characteristic = link.characteristic ?: return
        val head = link.writes.peek() ?: return
        val started = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    characteristic,
                    head.bytes,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                characteristic.value = head.bytes
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(characteristic)
            }
        } catch (_: Throwable) {
            false
        }
        if (started) {
            link.writes.poll()
            link.writing = true
            val token = ++link.writeToken
            // onCharacteristicWrite may never come if the link half-dies.
            main.postDelayed({
                if (link.writing && link.writeToken == token) {
                    link.writing = false
                    pumpClient(link)
                }
            }, WRITE_WATCHDOG_MS)
        } else if (++head.attempts >= MAX_ATTEMPTS) {
            link.writes.poll()
            main.postDelayed({ pumpClient(link) }, 50)
        } else {
            main.postDelayed({ pumpClient(link) }, 50)
        }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, state: Int) {
            main.post {
                if (state == BluetoothProfile.STATE_DISCONNECTED) {
                    serverMtu.remove(device.address)
                    preparedWrites.remove(device.address)
                    inbound.remove("s:${device.address}")
                    lastHeard.remove("s:${device.address}")
                    removeServerLink(device.address)
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            main.post {
                serverMtu[device.address] = mtu
                pumpNotifications()
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic,
        ) {
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, ByteArray(0))
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            if (preparedWrite) {
                // A long write: parts arrive here and the whole packet on execute.
                main.post {
                    val buffer = preparedWrites.getOrPut(device.address) { ByteArrayOutputStream() }
                    val ok = value != null && offset == buffer.size() &&
                        buffer.size() + value.size <= 4096
                    if (ok) buffer.write(value!!) else preparedWrites.remove(device.address)
                    if (responseNeeded) {
                        server?.sendResponse(
                            device,
                            requestId,
                            if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_INVALID_OFFSET,
                            offset,
                            value,
                        )
                    }
                }
                return
            }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
            if (value != null) deliver("s:${device.address}", value.copyOf())
        }

        @SuppressLint("MissingPermission")
        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            main.post {
                val buffer = preparedWrites.remove(device.address)
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
                if (execute && buffer != null) deliver("s:${device.address}", buffer.toByteArray())
            }
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray?,
        ) {
            main.post {
                val enable = value != null && value.isNotEmpty() && value[0].toInt() != 0
                if (enable && !servers.containsKey(device.address) && servers.size >= MAX_SERVER_LINKS) {
                    // Make room by dropping a central that has gone quiet.
                    servers.values
                        .filter { idle("s:${it.device.address}", it.since) }
                        .minByOrNull { lastHeard["s:${it.device.address}"] ?: it.since }
                        ?.let { quiet ->
                            try {
                                server?.cancelConnection(quiet.device)
                            } catch (_: Throwable) {
                            }
                            removeServerLink(quiet.device.address)
                        }
                }
                val full = enable && !servers.containsKey(device.address) &&
                    servers.size >= MAX_SERVER_LINKS
                if (responseNeeded) {
                    server?.sendResponse(
                        device,
                        requestId,
                        if (full) BluetoothGatt.GATT_FAILURE else BluetoothGatt.GATT_SUCCESS,
                        0,
                        null,
                    )
                }
                if (full) return@post
                if (enable && !servers.containsKey(device.address)) {
                    servers[device.address] = ServerLink(device)
                    emit(mapOf("link" to "s:${device.address}", "up" to true))
                } else if (!enable) {
                    removeServerLink(device.address)
                }
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            main.post {
                // A late answer for a notification the watchdog gave up on
                // must not end the one in flight to someone else.
                if (notifying?.device?.address != device.address) return@post
                notifying = null
                notifyToken++
                pumpNotifications()
            }
        }
    }

    private fun removeServerLink(address: String) {
        val link = servers.remove(address) ?: return
        if (notifying === link) {
            notifying = null
            notifyToken++
        }
        emit(mapOf("link" to "s:$address", "up" to false))
        pumpNotifications()
    }

    /**
     * Android sends one notification at a time: serve subscribers in turn so
     * one slow or vanished central cannot hold back the others.
     */
    @SuppressLint("MissingPermission")
    private fun pumpNotifications() {
        if (notifying != null) return
        val gattServer = server ?: return
        val characteristic = serverCharacteristic ?: return
        val link = servers.values.firstOrNull { link ->
            link.queue.isNotEmpty() && (serverMtu[link.device.address] ?: 23) >= MIN_MTU
        } ?: return
        // Rotate: the served link goes to the back of the order.
        servers.remove(link.device.address)
        servers[link.device.address] = link
        val head = link.queue.peek() ?: return
        val started = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gattServer.notifyCharacteristicChanged(link.device, characteristic, false, head.bytes) ==
                    BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = head.bytes
                @Suppress("DEPRECATION")
                gattServer.notifyCharacteristicChanged(link.device, characteristic, false)
            }
        } catch (_: Throwable) {
            false
        }
        if (started) {
            link.queue.poll()
            notifying = link
            val token = ++notifyToken
            // onNotificationSent may never come if the central vanishes.
            main.postDelayed({
                if (notifyToken == token) {
                    notifying = null
                    notifyToken++
                    pumpNotifications()
                }
            }, NOTIFY_WATCHDOG_MS)
        } else {
            if (++head.attempts >= MAX_ATTEMPTS) link.queue.poll()
            main.postDelayed({ pumpNotifications() }, 50)
        }
    }

    /** Queues [bytes] for every neighbour but [except]; answers how many. Main thread. */
    private fun broadcast(bytes: ByteArray, except: String?): Int {
        if (!active || bytes.isEmpty() || bytes.size > MAX_PACKET) return 0
        var queued = 0
        for (link in clients.values.toList()) {
            if ("c:${link.address}" == except || !link.ready) continue
            if (link.writes.size < MAX_QUEUED_PER_LINK) {
                link.writes.add(Outgoing(bytes))
                queued++
            }
            pumpClient(link)
        }
        for ((address, link) in servers) {
            if ("s:$address" == except || (serverMtu[address] ?: 23) < MIN_MTU) continue
            if (link.queue.size < MAX_QUEUED_PER_LINK) {
                link.queue.add(Outgoing(bytes))
                queued++
            }
        }
        pumpNotifications()
        return queued
    }
}
