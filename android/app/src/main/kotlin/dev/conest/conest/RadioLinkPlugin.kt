package dev.conest.conest

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.hoho.android.usbserial.driver.CdcAcmSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import com.hoho.android.usbserial.util.SerialInputOutputManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Byte links to radios (RNode, Meshtastic, MeshCore) for the Dart side:
 * USB serial devices and Bluetooth LE serial (Nordic UART service).
 *
 * Methods on [METHODS]: listUsb, openUsb {id, baud}, scanBle {timeoutMs},
 * openBle {address, messages}, write {handle, bytes}, close {handle}.
 * Events on [EVENTS]: {handle, data} for received bytes and
 * {handle, closed, error} when a link ends.
 *
 * USB devices are named "vendor:product" in hex, which stays the same when
 * the radio is plugged in again (the system device name does not).
 */
class RadioLinkPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        const val METHODS = "dev.conest/radio"
        const val EVENTS = "dev.conest/radio/events"
        private const val USB_PERMISSION = "dev.conest.conest.USB_PERMISSION"
        private val NUS_SERVICE: UUID =
            UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        private val NUS_RX: UUID =
            UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
        private val NUS_TX: UUID =
            UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
        private val CCCD: UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** The engine is configured once per process; a new plugin replaces
         *  the previous one and closes its links. */
        private var current: RadioLinkPlugin? = null
    }

    private interface Link {
        fun write(bytes: ByteArray, done: (String?) -> Unit)
        fun close()
    }

    private val main = Handler(Looper.getMainLooper())
    private val usbWrites = Executors.newSingleThreadExecutor()
    private val links = ConcurrentHashMap<Int, Link>()
    private val nextHandle = AtomicInteger(1)
    private var events: EventChannel.EventSink? = null

    init {
        current?.closeAll()
        current = this
        MethodChannel(messenger, METHODS).setMethodCallHandler(this)
        EventChannel(messenger, EVENTS).setStreamHandler(this)
    }

    private fun closeAll() {
        for ((handle, link) in links) {
            link.close()
            links.remove(handle)
        }
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

    private fun closed(handle: Int, error: String?) {
        if (links.remove(handle) != null) {
            emit(mapOf("handle" to handle, "closed" to true, "error" to error))
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "listUsb" -> result.success(listUsb())
                "openUsb" -> openUsb(
                    call.argument<String>("id") ?: "",
                    call.argument<Int>("baud") ?: 115200,
                    result,
                )
                "scanBle" -> scanBle(call.argument<Int>("timeoutMs") ?: 5000, result)
                "openBle" -> openBle(
                    call.argument<String>("address") ?: "",
                    call.argument<Boolean>("messages") == true,
                    result,
                )
                "write" -> {
                    val link = links[call.argument<Int>("handle") ?: -1]
                    if (link == null) {
                        result.error("closed", "The radio link is closed.", null)
                    } else {
                        link.write(call.argument<ByteArray>("bytes") ?: ByteArray(0)) { error ->
                            main.post {
                                if (error == null) {
                                    result.success(null)
                                } else {
                                    result.error("write", error, null)
                                }
                            }
                        }
                    }
                }
                "close" -> {
                    val handle = call.argument<Int>("handle") ?: -1
                    links[handle]?.close()
                    closed(handle, null)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error("radio", error.message ?: error.toString(), null)
        }
    }

    // USB serial.

    private val usbManager: UsbManager
        get() = context.getSystemService(Context.USB_SERVICE) as UsbManager

    private fun usbId(device: UsbDevice) = "%04x:%04x".format(device.vendorId, device.productId)

    private fun listUsb(): List<Map<String, Any?>> =
        usbManager.deviceList.values.map { device ->
            mapOf(
                "id" to usbId(device),
                "name" to (device.productName ?: usbId(device)),
                "vendorId" to device.vendorId,
                "productId" to device.productId,
                "supported" to (UsbSerialProber.getDefaultProber().probeDevice(device) != null),
            )
        }

    private fun openUsb(id: String, baud: Int, result: MethodChannel.Result) {
        val device = usbManager.deviceList.values.firstOrNull {
            usbId(it) == id || it.deviceName == id
        }
        if (device == null) {
            result.error("missing", "The USB device is not connected.", null)
            return
        }
        if (usbManager.hasPermission(device)) {
            openUsbNow(device, baud, result)
            return
        }
        var answered = false
        lateinit var receiver: BroadcastReceiver
        fun finish(granted: Boolean) {
            if (answered) return
            answered = true
            try {
                context.unregisterReceiver(receiver)
            } catch (_: Throwable) {
            }
            if (granted) {
                openUsbNow(device, baud, result)
            } else {
                result.error("denied", "USB access was not allowed.", null)
            }
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context, intent: Intent) {
                if (intent.action != USB_PERMISSION) return
                @Suppress("DEPRECATION")
                val answeredFor = intent.getParcelableExtra<UsbDevice>(UsbManager.EXTRA_DEVICE)
                if (answeredFor != null && answeredFor.deviceName != device.deviceName) return
                finish(intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
            }
        }
        val filter = IntentFilter(USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val intent = Intent(USB_PERMISSION).setPackage(context.packageName)
        usbManager.requestPermission(
            device,
            PendingIntent.getBroadcast(context, device.deviceId, intent, flags),
        )
        // A dialog left unanswered must not keep the receiver forever.
        main.postDelayed({ finish(false) }, 120_000)
    }

    private fun openUsbNow(device: UsbDevice, baud: Int, result: MethodChannel.Result) {
        try {
            val driver = UsbSerialProber.getDefaultProber().probeDevice(device)
                ?: CdcAcmSerialDriver(device)
            val connection = usbManager.openDevice(device)
                ?: throw IllegalStateException("The USB device could not be opened.")
            val port = driver.ports.first()
            port.open(connection)
            port.setParameters(baud, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
            val handle = nextHandle.getAndIncrement()
            val io = SerialInputOutputManager(
                port,
                object : SerialInputOutputManager.Listener {
                    override fun onNewData(data: ByteArray) {
                        emit(mapOf("handle" to handle, "data" to data))
                    }

                    override fun onRunError(error: Exception) {
                        try {
                            port.close()
                        } catch (_: Throwable) {
                        }
                        closed(handle, error.message ?: error.toString())
                    }
                },
            )
            links[handle] = object : Link {
                override fun write(bytes: ByteArray, done: (String?) -> Unit) {
                    // Off the platform thread: a write may block briefly.
                    usbWrites.execute {
                        try {
                            port.write(bytes, 2000)
                            done(null)
                        } catch (error: Throwable) {
                            done(error.message ?: error.toString())
                        }
                    }
                }

                override fun close() {
                    io.stop()
                    try {
                        port.close()
                    } catch (_: Throwable) {
                    }
                }
            }
            io.start()
            result.success(handle)
        } catch (error: Throwable) {
            result.error("usb", error.message ?: error.toString(), null)
        }
    }

    // Bluetooth LE serial (Nordic UART service).

    private val bluetooth
        get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    @SuppressLint("MissingPermission")
    private fun scanBle(timeoutMs: Int, result: MethodChannel.Result) {
        val scanner = bluetooth?.bluetoothLeScanner
        if (scanner == null) {
            result.error("bluetooth", "Bluetooth is off or missing.", null)
            return
        }
        val found = LinkedHashMap<String, Map<String, Any?>>()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, scan: ScanResult) {
                val name = scan.scanRecord?.deviceName ?: scan.device.name ?: return
                main.post {
                    found[scan.device.address] = mapOf(
                        "address" to scan.device.address,
                        "name" to name,
                        "rssi" to scan.rssi,
                    )
                }
            }
        }
        scanner.startScan(callback)
        main.postDelayed({
            try {
                scanner.stopScan(callback)
            } catch (_: Throwable) {
            }
            result.success(found.values.toList())
        }, timeoutMs.toLong().coerceIn(1000, 30000))
    }

    /**
     * Opens a Nordic UART device. All link state lives on the main thread;
     * GATT callbacks hand over to it. With [messages], each write is one
     * characteristic write and must fit the MTU (MeshCore); otherwise bytes
     * are split as needed (RNode).
     */
    @SuppressLint("MissingPermission")
    private fun openBle(address: String, messages: Boolean, result: MethodChannel.Result) {
        val adapter = bluetooth
        if (adapter == null || !adapter.isEnabled) {
            result.error("bluetooth", "Bluetooth is off or missing.", null)
            return
        }
        val device = adapter.getRemoteDevice(address)
        val handle = nextHandle.getAndIncrement()
        val writes = ArrayDeque<Pair<ByteArray, ((String?) -> Unit)?>>()
        var mtu = 23
        var writing = false
        var answered = false
        var finished = false
        var rx: BluetoothGattCharacteristic? = null
        lateinit var gatt: BluetoothGatt

        fun answer(error: String?) {
            if (answered) return
            answered = true
            if (error == null) result.success(handle) else result.error("ble", error, null)
        }

        fun shutDown(error: String?) {
            if (finished) return
            finished = true
            answer(error ?: "The radio disconnected.")
            try {
                gatt.disconnect()
            } catch (_: Throwable) {
            }
            try {
                gatt.close()
            } catch (_: Throwable) {
            }
            while (writes.isNotEmpty()) writes.poll()?.second?.invoke("Bluetooth disconnected.")
            closed(handle, error ?: "Bluetooth disconnected.")
        }

        fun pump() {
            if (writing || finished) return
            val characteristic = rx ?: return
            val (chunk, done) = writes.peek() ?: return
            val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    characteristic,
                    chunk,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                characteristic.value = chunk
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(characteristic)
            }
            if (started) {
                writing = true
                writes.poll()
                done?.invoke(null)
            } else {
                // Busy: try again shortly rather than stall the queue.
                main.postDelayed({ pump() }, 50)
            }
        }

        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, state: Int) {
                main.post {
                    if (state == BluetoothProfile.STATE_CONNECTED) {
                        g.requestMtu(517)
                    } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                        shutDown(null)
                    }
                }
            }

            override fun onMtuChanged(g: BluetoothGatt, newMtu: Int, status: Int) {
                main.post {
                    mtu = newMtu
                    g.discoverServices()
                }
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                main.post {
                    val service = g.getService(NUS_SERVICE)
                    val tx = service?.getCharacteristic(NUS_TX)
                    val characteristic = service?.getCharacteristic(NUS_RX)
                    if (tx == null || characteristic == null) {
                        shutDown("The device has no serial (Nordic UART) service.")
                        return@post
                    }
                    rx = characteristic
                    g.setCharacteristicNotification(tx, true)
                    val descriptor = tx.getDescriptor(CCCD)
                    if (descriptor == null) {
                        answer(null)
                        return@post
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        g.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                    } else {
                        @Suppress("DEPRECATION")
                        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        @Suppress("DEPRECATION")
                        g.writeDescriptor(descriptor)
                    }
                }
            }

            override fun onDescriptorWrite(
                g: BluetoothGatt,
                descriptor: BluetoothGattDescriptor,
                status: Int,
            ) {
                main.post {
                    when (status) {
                        BluetoothGatt.GATT_SUCCESS -> answer(null)
                        // Insufficient authentication or encryption: the
                        // radio wants to be paired (with the PIN it shows).
                        5, 15, 137 -> shutDown(
                            "Pair the radio in Android's Bluetooth settings first " +
                                "(enter the PIN it shows), then try again.",
                        )
                        else -> shutDown("The radio refused notifications ($status).")
                    }
                }
            }

            override fun onCharacteristicWrite(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                main.post {
                    writing = false
                    pump()
                }
            }

            @Deprecated("Deprecated in API 33")
            override fun onCharacteristicChanged(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                @Suppress("DEPRECATION")
                val value = characteristic.value ?: return
                emit(mapOf("handle" to handle, "data" to value.copyOf()))
            }

            override fun onCharacteristicChanged(
                g: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) {
                emit(mapOf("handle" to handle, "data" to value))
            }
        }
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        links[handle] = object : Link {
            override fun write(bytes: ByteArray, done: (String?) -> Unit) {
                main.post {
                    if (finished) {
                        done("Bluetooth disconnected.")
                        return@post
                    }
                    val size = (mtu - 3).coerceAtLeast(20)
                    if (bytes.isEmpty()) {
                        done(null)
                        return@post
                    }
                    if (messages) {
                        if (bytes.size > size) {
                            done("The message is larger than the Bluetooth MTU allows.")
                            return@post
                        }
                        writes.add(bytes to done)
                    } else {
                        var offset = 0
                        while (offset < bytes.size) {
                            val end = minOf(offset + size, bytes.size)
                            writes.add(bytes.copyOfRange(offset, end) to (if (end == bytes.size) done else null))
                            offset = end
                        }
                    }
                    pump()
                }
            }

            override fun close() {
                main.post { shutDown(null) }
            }
        }
        main.postDelayed({
            if (!answered) shutDown("The radio did not answer over Bluetooth.")
        }, 20000)
    }
}
