package robot.duckbuddy.microduck.state

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import uniffi.duck_core.Advertisement
import uniffi.duck_core.parseAdvertisement
import uniffi.duck_core.rpcCharacteristicUuid
import uniffi.duck_core.serviceUuid
import java.util.UUID

/** 附近的一只鸭子（扫描结果）。 */
data class NearbyRobot(val advert: Advertisement, val rssi: Int, val device: BluetoothDevice?, val lastSeen: Long) {
    val id get() = advert.name
    val bars get() = when { rssi >= -60 -> 3; rssi >= -75 -> 2; rssi >= -88 -> 1; else -> 0 }
}

/**
 * Android 蓝牙平台层：扫描、连接、显式配对（`createBond`，监听 `ACTION_BOND_STATE_CHANGED`）、
 * 读一次 RPC 特征、订阅、按顺序写。不解析任何协议字节——全部交给 duck-core 的 `DuckLink`。
 *
 * 官方实测：部分 Android 手机上"由 GATT 读触发的自动配对"会超时，所以先显式 `createBond()` 再访问受保护特征。
 * 配对被拒时仍尝试读一次：不要求配对的机器人照样能连。
 */
@SuppressLint("MissingPermission")
class BleCentral(private val ctx: Context) {
    sealed class LinkError(msg: String) : Exception(msg) {
        object PoweredOff : LinkError("bluetooth off")
        object NotFound : LinkError("not found")
        object PairingCancelled : LinkError("pairing cancelled")
        object Disconnected : LinkError("disconnected")
    }

    var nearby: Map<String, NearbyRobot> = emptyMap(); private set
    var onNearbyChange: (() -> Unit)? = null
    var onReady: ((Int) -> Unit)? = null
    var onData: ((ByteArray) -> Unit)? = null
    var onDisconnect: ((Exception?) -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    private val manager = ctx.getSystemService(BluetoothManager::class.java)
    private val adapter get() = manager?.adapter
    private val serviceId = UUID.fromString(serviceUuid())
    private val rpcId = UUID.fromString(rpcCharacteristicUuid())
    private val cccd = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    private var gatt: BluetoothGatt? = null
    private var rpc: BluetoothGattCharacteristic? = null
    private var mtu = 23
    private val queue = ArrayDeque<ByteArray>()
    private var writing = false
    private var scanning = false
    private var waitingBond: BluetoothDevice? = null

    val isPoweredOn get() = adapter?.isEnabled == true

    // ── 扫描 ──

    private val scanCb = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val rec = result.scanRecord ?: return
            val uuids = rec.serviceUuids?.map { it.uuid.toString() } ?: emptyList()
            val mfr = HashMap<UShort, ByteArray>()
            val sparse = rec.manufacturerSpecificData
            for (i in 0 until (sparse?.size() ?: 0)) mfr[sparse!!.keyAt(i).toUShort()] = sparse.valueAt(i)
            val connectable = if (Build.VERSION.SDK_INT >= 26) result.isConnectable else true
            val ad = parseAdvertisement(rec.deviceName ?: result.device.name, uuids, mfr, connectable) ?: return
            main.post {
                val existing = nearby[ad.name]
                // 扩展广播双胞胎优先：板子只接受扩展广播上的连接（authenticated-app-mvp.md）。
                if (existing != null && existing.advert.isExtended && !ad.isExtended &&
                    System.currentTimeMillis() - existing.lastSeen < 3000) return@post
                nearby = nearby + (ad.name to NearbyRobot(ad, result.rssi, result.device, System.currentTimeMillis()))
                onNearbyChange?.invoke()
            }
        }
    }

    fun startScan() {
        val scanner = adapter?.bluetoothLeScanner ?: return
        if (scanning) return
        scanning = true
        // 不按服务过滤：官方经验是扫描不过滤、由客户端自己甄别（mobile-app.md §2）。
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .apply { if (Build.VERSION.SDK_INT >= 26) setLegacy(false) }.build()
        runCatching { scanner.startScan(null, settings, scanCb) }
    }

    fun stopScan() {
        if (!scanning) return
        scanning = false
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCb) }
    }

    fun prune() {
        val cutoff = System.currentTimeMillis() - 6000
        val before = nearby.size
        nearby = nearby.filterValues { it.lastSeen > cutoff }
        if (nearby.size != before) onNearbyChange?.invoke()
    }

    // ── 连接 ──

    fun connect(device: BluetoothDevice) {
        disconnect()
        gatt = device.connectGatt(ctx, false, gattCb, BluetoothDevice.TRANSPORT_LE)
    }

    fun disconnect() {
        gatt?.let { g ->
            rpc?.let { runCatching { g.setCharacteristicNotification(it, false) } }
            runCatching { g.disconnect(); g.close() }
        }
        gatt = null
        rpc = null
        queue.clear()
        writing = false
    }

    fun write(chunks: List<ByteArray>) {
        queue.addAll(chunks)
        pump()
    }

    @Suppress("DEPRECATION")
    private fun pump() {
        val g = gatt ?: return
        val c = rpc ?: return
        if (writing || queue.isEmpty()) return
        writing = true
        val data = queue.removeFirst()
        if (Build.VERSION.SDK_INT >= 33) {
            g.writeCharacteristic(c, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
        } else {
            c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            c.value = data
            g.writeCharacteristic(c)
        }
    }

    private val bondReceiver: BroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val dev: BluetoothDevice? = if (Build.VERSION.SDK_INT >= 33)
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
            if (dev?.address != waitingBond?.address) return
            when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)) {
                BluetoothDevice.BOND_BONDED -> { waitingBond = null; unregister(); readVersion() }
                // 配对被拒不一定是失败：`btd --insecure-no-pairing` 的机器人不可配对、也不要求加密，
                // 这时直接读特征就能用（iOS 不显式配对，所以一直能连）。读也失败才算配对失败。
                BluetoothDevice.BOND_NONE -> { waitingBond = null; unregister(); readVersion() }
            }
        }
    }

    private fun unregister() { runCatching { ctx.unregisterReceiver(bondReceiver) } }

    private fun fail(e: Exception) { main.post { onDisconnect?.invoke(e) } }

    @Suppress("DEPRECATION")
    private fun readVersion() {
        val g = gatt ?: return
        val c = rpc ?: return
        // 先读一次：需要加密链路，读到的是机器人的 API 版本（gatt.rs）。
        g.readCharacteristic(c)
    }

    private val gattCb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.requestMtu(517)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                main.post {
                    if (g != gatt) return@post
                    rpc = null; queue.clear(); writing = false
                    onDisconnect?.invoke(if (status == BluetoothGatt.GATT_SUCCESS) null else LinkError.Disconnected)
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, newMtu: Int, status: Int) {
            mtu = if (status == BluetoothGatt.GATT_SUCCESS) newMtu else 23
            g.discoverServices()
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val c = g.getService(serviceId)?.getCharacteristic(rpcId)
            if (c == null) { fail(LinkError.NotFound); return }
            main.post {
                rpc = c
                val dev = g.device
                if (dev.bondState == BluetoothDevice.BOND_BONDED) readVersion()
                else {
                    waitingBond = dev
                    ContextCompat.registerReceiver(ctx, bondReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),
                        ContextCompat.RECEIVER_EXPORTED)
                    if (!dev.createBond()) readVersion() // 系统拒绝显式配对时退回 GATT 触发
                }
            }
        }

        @Deprecated("API < 33")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) = afterRead(g, c, status)

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) = afterRead(g, c, status)

        @Suppress("DEPRECATION")
        private fun afterRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) { fail(LinkError.PairingCancelled); return }
            g.setCharacteristicNotification(c, true)
            val d = c.getDescriptor(cccd) ?: run { main.post { onReady?.invoke(mtu) }; return }
            if (Build.VERSION.SDK_INT >= 33) g.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            else { d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; g.writeDescriptor(d) }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) main.post { onReady?.invoke(mtu) } else fail(LinkError.Disconnected)
        }

        @Deprecated("API < 33")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            val v = c.value ?: return
            main.post { onData?.invoke(v) }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            main.post { onData?.invoke(value) }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            main.post {
                writing = false
                if (status != BluetoothGatt.GATT_SUCCESS) queue.clear() else pump()
            }
        }
    }
}
