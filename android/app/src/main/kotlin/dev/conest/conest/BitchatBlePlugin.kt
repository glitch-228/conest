package dev.conest.conest

import android.annotation.SuppressLint
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
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.UUID

/**
 * The bitchat Bluetooth mesh transport: Conest acts as both a peripheral
 * (GATT server with bitchat's service, advertised) and a central (scans
 * for that service, connects, subscribes). Every neighbour is a link that
 * carries whole bitchat packets; the mesh logic runs in Dart.
 *
 * Methods on [METHODS]: start, stop, broadcast {bytes, except}. Events on
 * [EVENTS]: {link, data} for received packets and {link, up} when a
 * neighbour comes or goes. All state lives on the main thread.
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
        private const val MAX_PACKET = 512
        private var current: BitchatBlePlugin? = null
    }

    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var running = false
    private var server: BluetoothGattServer? = null
    private var serverCharacteristic: BluetoothGattCharacteristic? = null
    private val subscribed = LinkedHashMap<String, BluetoothDevice>()
    private val notifyQueue = ArrayDeque<Pair<BluetoothDevice, ByteArray>>()
    private var notifying = false
    private val clients = LinkedHashMap<String, ClientLink>()

    private inner class ClientLink(val address: String) {
        var gatt: BluetoothGatt? = null
        var characteristic: BluetoothGattCharacteristic? = null
        val writes = ArrayDeque<ByteArray>()
        var writing = false
        var ready = false
    }

    init {
        current?.stopAll()
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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "start" -> {
                    startAll()
                    result.success(null)
                }
                "stop" -> {
                    stopAll()
                    result.success(null)
                }
                "broadcast" -> {
                    broadcast(
                        call.argument<ByteArray>("bytes") ?: ByteArray(0),
                        call.argument<String>("except"),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error("bitchat", error.message ?: error.toString(), null)
        }
    }

    private val manager: BluetoothManager
        get() = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager

    @SuppressLint("MissingPermission")
    private fun startAll() {
        if (running) return
        val adapter = manager.adapter ?: throw IllegalStateException("Bluetooth is missing.")
        if (!adapter.isEnabled) throw IllegalStateException("Bluetooth is off.")
        running = true
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
        server = manager.openGattServer(context, serverCallback)?.also { it.addService(service) }
        adapter.bluetoothLeAdvertiser?.startAdvertising(
            AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(true)
                .build(),
            AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).build(),
            advertiseCallback,
        )
        // Central: find and join neighbours.
        adapter.bluetoothLeScanner?.startScan(
            listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()),
            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build(),
            scanCallback,
        )
    }

    @SuppressLint("MissingPermission")
    private fun stopAll() {
        if (!running) return
        running = false
        val adapter = manager.adapter
        try {
            adapter?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (_: Throwable) {
        }
        try {
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        } catch (_: Throwable) {
        }
        for (link in clients.values) {
            try {
                link.gatt?.disconnect()
                link.gatt?.close()
            } catch (_: Throwable) {
            }
        }
        clients.clear()
        try {
            server?.close()
        } catch (_: Throwable) {
        }
        server = null
        subscribed.clear()
        notifyQueue.clear()
        notifying = false
    }

    private val advertiseCallback = object : AdvertiseCallback() {}

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post { connectTo(result.device) }
        }
    }

    @SuppressLint("MissingPermission")
    private fun connectTo(device: BluetoothDevice) {
        if (!running || clients.containsKey(device.address) ||
            subscribed.containsKey(device.address) || clients.size >= MAX_CLIENT_LINKS
        ) {
            return
        }
        val link = ClientLink(device.address)
        clients[device.address] = link
        link.gatt = device.connectGatt(context, false, clientCallback(link), BluetoothDevice.TRANSPORT_LE)
    }

    @SuppressLint("MissingPermission")
    private fun clientCallback(link: ClientLink) = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, state: Int) {
            main.post {
                if (state == BluetoothProfile.STATE_CONNECTED && running) {
                    gatt.requestMtu(517)
                } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                    dropClient(link)
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            main.post { gatt.discoverServices() }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            main.post {
                val characteristic = gatt.getService(SERVICE)?.getCharacteristic(CHARACTERISTIC)
                if (characteristic == null) {
                    dropClient(link)
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
            main.post { linkUp(link) }
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
            emit(mapOf("link" to "c:${link.address}", "data" to value.copyOf()))
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            emit(mapOf("link" to "c:${link.address}", "data" to value))
        }
    }

    private fun linkUp(link: ClientLink) {
        if (link.ready) return
        link.ready = true
        emit(mapOf("link" to "c:${link.address}", "up" to true))
        pumpClient(link)
    }

    @SuppressLint("MissingPermission")
    private fun dropClient(link: ClientLink) {
        if (clients.remove(link.address) == null) return
        try {
            link.gatt?.close()
        } catch (_: Throwable) {
        }
        emit(mapOf("link" to "c:${link.address}", "up" to false))
    }

    @SuppressLint("MissingPermission")
    private fun pumpClient(link: ClientLink) {
        if (link.writing || !link.ready) return
        val gatt = link.gatt ?: return
        val characteristic = link.characteristic ?: return
        val bytes = link.writes.peek() ?: return
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gatt.writeCharacteristic(
                characteristic,
                bytes,
                BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
            ) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            @Suppress("DEPRECATION")
            characteristic.value = bytes
            @Suppress("DEPRECATION")
            gatt.writeCharacteristic(characteristic)
        }
        if (started) {
            link.writes.poll()
            link.writing = true
        } else {
            main.postDelayed({ pumpClient(link) }, 50)
        }
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, state: Int) {
            main.post {
                if (state == BluetoothProfile.STATE_DISCONNECTED &&
                    subscribed.remove(device.address) != null
                ) {
                    emit(mapOf("link" to "s:${device.address}", "up" to false))
                }
            }
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
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
            if (value != null && value.isNotEmpty() && value.size <= 4096) {
                emit(mapOf("link" to "s:${device.address}", "data" to value.copyOf()))
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
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
            main.post {
                val enable = value != null && value.isNotEmpty() && value[0].toInt() != 0
                if (enable && subscribed.put(device.address, device) == null) {
                    emit(mapOf("link" to "s:${device.address}", "up" to true))
                } else if (!enable && subscribed.remove(device.address) != null) {
                    emit(mapOf("link" to "s:${device.address}", "up" to false))
                }
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            main.post {
                notifying = false
                pumpNotifications()
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun pumpNotifications() {
        if (notifying) return
        val gattServer = server ?: return
        val characteristic = serverCharacteristic ?: return
        val (device, bytes) = notifyQueue.peek() ?: return
        if (!subscribed.containsKey(device.address)) {
            notifyQueue.poll()
            pumpNotifications()
            return
        }
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            gattServer.notifyCharacteristicChanged(device, characteristic, false, bytes) ==
                BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            characteristic.value = bytes
            @Suppress("DEPRECATION")
            gattServer.notifyCharacteristicChanged(device, characteristic, false)
        }
        if (started) {
            notifyQueue.poll()
            notifying = true
        } else {
            main.postDelayed({ pumpNotifications() }, 50)
        }
    }

    private fun broadcast(bytes: ByteArray, except: String?) {
        if (!running || bytes.isEmpty() || bytes.size > MAX_PACKET) return
        main.post {
            for (link in clients.values) {
                if ("c:${link.address}" == except || !link.ready) continue
                if (link.writes.size < 256) link.writes.add(bytes)
                pumpClient(link)
            }
            for (device in subscribed.values) {
                if ("s:${device.address}" == except) continue
                if (notifyQueue.size < 1024) notifyQueue.add(device to bytes)
            }
            pumpNotifications()
        }
    }
}
