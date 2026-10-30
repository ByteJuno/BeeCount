package com.tntlikely.beecount

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** 前后台共用同一个引擎和数据库；不运行第二次 Dart main()。 */
internal object RootBillingBridge {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null
    var engine: FlutterEngine? = null
        private set
    private var attached = false
    @Volatile var running = false
    @Volatile var status = "stopped"

    fun attach(engine: FlutterEngine, context: Context) {
        val appContext = context.applicationContext
        this.engine = engine
        attached = true
        channel = MethodChannel(engine.dartExecutor.binaryMessenger,
            "com.tntlikely.beecount/root_billing").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(mapOf("running" to running, "status" to status,
                        "supported" to (BuildConfig.ROOT_AUTO_BILLING_ENABLED && Build.VERSION.SDK_INT >= 26)))
                    "start" -> {
                        if (!BuildConfig.ROOT_AUTO_BILLING_ENABLED || Build.VERSION.SDK_INT < 26) {
                            result.error("UNSUPPORTED", "Root billing is unavailable in this build", null)
                        } else if (running) {
                            result.success(true)
                        } else {
                            worker.execute {
                                val failure = try {
                                    RootBillingShell(appContext.applicationInfo.sourceDir).use {
                                        if (!it.checkRoot()) "ROOT_DENIED"
                                        else {
                                            it.probeReader()
                                            null
                                        }
                                    }
                                } catch (error: RootReaderUnavailable) { error.code }
                                catch (_: Exception) { "READER_UNAVAILABLE" }
                                main.post {
                                    if (failure != null) {
                                        result.error(failure, "Root recognition could not start", null)
                                    } else {
                                        try {
                                            appContext.startForegroundService(Intent(appContext, RootBillingService::class.java))
                                            result.success(true)
                                        } catch (_: Exception) {
                                            result.error("START_FAILED", "Could not start Root billing", null)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    "stop" -> {
                        appContext.stopService(Intent(appContext, RootBillingService::class.java))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun activityDetached() { attached = false }

    fun updateStatus(value: String) {
        status = value
        main.post { channel?.invokeMethod("statusChanged", mapOf("running" to running, "status" to value)) }
    }

    fun deliver(payload: Map<String, Any>, completed: (Boolean) -> Unit) {
        main.post {
            val bridge = channel
            if (bridge == null) {
                completed(false)
                return@post
            }
            val once = AtomicBoolean(false)
            fun finish(ok: Boolean) { if (once.compareAndSet(false, true)) completed(ok) }
            val timeout = Runnable { finish(false) }
            main.postDelayed(timeout, 15000)
            bridge.invokeMethod("capture", payload, object : MethodChannel.Result {
                override fun success(result: Any?) { main.removeCallbacks(timeout); finish(true) }
                override fun error(code: String, message: String?, details: Any?) { main.removeCallbacks(timeout); finish(false) }
                override fun notImplemented() { main.removeCallbacks(timeout); finish(false) }
            })
        }
    }

    fun serviceStopped() {
        running = false
        updateStatus(if (status == "captureFailed") status else "stopped")
        // 服务停止后，已无 Activity 的引擎才销毁；前台引擎交回 Activity 管理。
        if (!attached) {
            engine?.destroy()
            engine = null
            channel = null
        }
    }
}
