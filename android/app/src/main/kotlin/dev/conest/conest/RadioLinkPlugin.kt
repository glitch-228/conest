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
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger

/**
 * Byte links to radios (RNode, Meshtastic, MeshCore) for the Dart side:
 * USB serial devices and Bluetooth LE serial (Nordic UART service).
 *
 * Methods on [METHODS]: listUsb, openUsb {id, baud}, scanBle {timeoutMs},
 * openBle {address}, write {handle, bytes}, close {handle}. Events on
 * [EVENTS]: {handle, data} for received bytes and {handle, closed, error}
 * when a link ends.
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
    }

    private interface Link {
        fun write(bytes: ByteArray)
        fun close()
    }

    private val main = Handler(Looper.getMainLooper())
    private val links = ConcurrentHashMap<Int, Link>()
    private val nextHandle = AtomicInteger(1)
    private var events: EventChannel.EventSink? = null

    init {
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
                "openBle" -> openBle(call.argument<String>("address") ?: "", result)
                "write" -> {
                    val link = links[call.argument<Int>("handle") ?: -1]
                    if (link == null) {
                        result.error("closed", "The radio link is closed.", null)
                    } else {
                        link.write(call.argument<ByteArray>("bytes") ?: ByteArray(0))
                        result.success(null)
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

    private fun listUsb(): List<Map<String, Any?>> =
        usbManager.deviceList.values.map { device ->
            mapOf(
                "id" to device.deviceName,
                "name" to (device.productName ?: device.deviceName),
                "vendorId" to device.vendorId,
                "productId" to device.productId,
                "supported" to (UsbSerialProber.getDefaultProber().probeDevice(device) != null),
            )
        }

    private fun openUsb(id: String, baud: Int, result: MethodChannel.Result) {
        val device = usbManager.deviceList[id]
        if (device == null) {
            result.error("missing", "The USB device is not connected.", null)
            return
        }
        if (usbManager.hasPermission(device)) {
            openUsbNow(device, baud, result)
            return
        }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(receiverContext: Context, intent: Intent) {
                if (intent.action != USB_PERMISSION) return
                context.unregisterReceiver(this)
                if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                    openUsbNow(device, baud, result)
                } else {
                    result.error("denied", "USB access was not allowed.", null)
                }
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
            PendingIntent.getBroadcast(context, 0, intent, flags),
        )
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
                override fun write(bytes: ByteArray) = port.write(bytes, 2000)

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
                found[scan.device.address] = mapOf(
                    "address" to scan.device.address,
                    "name" to name,
                    "rssi" to scan.rssi,
                )
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

    @SuppressLint("MissingPermission")
    private fun openBle(address: String, result: MethodChannel.Result) {
        val adapter = bluetooth
        if (adapter == null || !adapter.isEnabled) {
            result.error("bluetooth", "Bluetooth is off or missing.", null)
            return
        }
        val device = adapter.getRemoteDevice(address)
        val handle = nextHandle.getAndIncrement()
        val writes = LinkedBlockingQueue<ByteArray>()
        var mtu = 23
        var writing = false
        var answered = false
        var rx: BluetoothGattCharacteristic? = null

        fun answer(error: String?) {
            if (answered) return
            answered = true
            main.post {
                if (error == null) result.success(handle) else result.error("ble", error, null)
            }
        }

        lateinit var gatt: BluetoothGatt

        fun pump() {
            if (writing) return
            val characteristic = rx ?: return
            val chunk = writes.poll() ?: return
            writing = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(
                    characteristic,
                    chunk,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                )
            } else {
                @Suppress("DEPRECATION")
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                characteristic.value = chunk
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(characteristic)
            }
        }

        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, state: Int) {
                if (state == BluetoothProfile.STATE_CONNECTED) {
                    g.requestMtu(517)
                } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                    g.close()
                    answer("The radio disconnected.")
                    closed(handle, "Bluetooth disconnected.")
                }
            }

            override fun onMtuChanged(g: BluetoothGatt, newMtu: Int, status: Int) {
                mtu = newMtu
                g.discoverServices()
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                val service = g.getService(NUS_SERVICE)
                val tx = service?.getCharacteristic(NUS_TX)
                rx = service?.getCharacteristic(NUS_RX)
                if (tx == null || rx == null) {
                    answer("The device has no serial (Nordic UART) service.")
                    g.disconnect()
                    return
                }
                g.setCharacteristicNotification(tx, true)
                val descriptor = tx.getDescriptor(CCCD)
                if (descriptor == null) {
                    answer(null)
                    return
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

            override fun onDescriptorWrite(
                g: BluetoothGatt,
                descriptor: BluetoothGattDescriptor,
                status: Int,
            ) {
                answer(if (status == BluetoothGatt.GATT_SUCCESS) null else "Notifications refused ($status).")
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
                emit(mapOf("handle" to handle, "data" to value))
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
            override fun write(bytes: ByteArray) {
                val size = (mtu - 3).coerceAtLeast(20)
                var offset = 0
                while (offset < bytes.size) {
                    val end = minOf(offset + size, bytes.size)
                    writes.add(bytes.copyOfRange(offset, end))
                    offset = end
                }
                main.post { pump() }
            }

            override fun close() {
                gatt.disconnect()
            }
        }
        main.postDelayed({
            if (!answered) {
                answer("The radio did not answer over Bluetooth.")
                links.remove(handle)
                gatt.disconnect()
            }
        }, 20000)
    }
}
