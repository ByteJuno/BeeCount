package com.tntlikely.beecount

import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** 用户明确开启的前台服务。锁屏停采，不拉起支付应用，不点击页面。 */
@android.annotation.TargetApi(26)
class RootBillingService : Service() {
    private val worker = Executors.newSingleThreadScheduledExecutor()
    private lateinit var shell: RootBillingShell
    private var previousFocus: Pair<String, String>? = null
    private var previousPage: String? = null
    private var observationId = UUID.randomUUID().toString()
    private var failures = 0

    override fun onCreate() {
        super.onCreate()
        if (!BuildConfig.ROOT_AUTO_BILLING_ENABLED || RootBillingBridge.engine == null) {
            stopSelf()
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL,
            getString(R.string.root_billing_title), NotificationManager.IMPORTANCE_LOW).apply {
            setShowBadge(false)
        })
        val stop = PendingIntent.getService(this, 0,
            Intent(this, RootBillingService::class.java).setAction(STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setContentTitle(getString(R.string.root_billing_title))
            .setContentText(getString(R.string.root_billing_running))
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, getString(R.string.root_billing_stop), stop).build())
            .build()
        startForeground(7301, notification)
        RootBillingBridge.running = true
        RootBillingBridge.updateStatus("running")
        shell = RootBillingShell(applicationInfo.sourceDir)
        worker.scheduleWithFixedDelay({ poll() }, 0, 3, TimeUnit.SECONDS)
    }

    private fun poll() {
        if (!RootBillingBridge.running) return
        val power = getSystemService(PowerManager::class.java)
        val keyguard = getSystemService(KeyguardManager::class.java)
        if (!power.isInteractive || keyguard.isKeyguardLocked) return
        try {
            val focus = shell.foreground()
            if (focus != previousFocus) {
                previousFocus = focus
                previousPage = null
                observationId = UUID.randomUUID().toString()
            }
            if (focus == null) return
            val nodes = shell.readNodes(focus.first)
            // 采集期间用户可能切换应用；不投递另一个窗口的页面内容。
            if (shell.foreground() != focus) return
            failures = 0
            RootBillingBridge.updateStatus("running")
            val joined = nodes.joinToString("\n")
            if (!Regex("支付成功|付款成功|交易成功|支付完成|已支付|退款成功|已全额退款|退款到账|退还成功|转账成功|提现成功|充值成功|还款成功|已收款").containsMatchIn(joined)) {
                previousPage = null
                observationId = UUID.randomUUID().toString()
                return
            }
            val signature = MessageDigest.getInstance("SHA-256").digest(joined.toByteArray())
                .joinToString("") { "%02x".format(it) }
            if (signature == previousPage) return
            val done = CountDownLatch(1)
            var accepted = false
            RootBillingBridge.deliver(mapOf("packageName" to focus.first, "nodes" to nodes,
                "observationId" to observationId, "observedAt" to System.currentTimeMillis())) {
                accepted = it
                done.countDown()
            }
            if (done.await(16, TimeUnit.SECONDS) && accepted) previousPage = signature
        } catch (_: Exception) {
            // 不在日志/通知中输出原始页面、金额、交易号或 su 输出。
            failures++
            RootBillingBridge.updateStatus("captureFailed")
            if (failures >= 3) stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) stopSelf()
        // 不通过闹钟/重启广播反复拉活；用户下次打开设置可明确重新启动。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        RootBillingBridge.running = false
        worker.shutdownNow()
        if (::shell.isInitialized) shell.close()
        RootBillingBridge.serviceStopped()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val CHANNEL = "root_auto_billing"
        private const val STOP = "com.tntlikely.beecount.STOP_ROOT_BILLING"
    }
}
