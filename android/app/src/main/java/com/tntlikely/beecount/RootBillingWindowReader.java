package com.tntlikely.beecount;

import android.app.UiAutomation;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.Process;
import android.view.accessibility.AccessibilityNodeInfo;
import java.lang.reflect.Constructor;
import org.json.JSONArray;

/** APK 内置的只读 Root 子进程入口，不依赖插件或 Kotlin/Flutter 运行时。 */
public final class RootBillingWindowReader {
    private RootBillingWindowReader() {}

    @SuppressWarnings("deprecation")
    public static void main(String[] args) {
        if ((Process.myUid() != 0 && Process.myUid() != 2000) ||
                !(args.length == 1 || (args.length == 2 && "--probe".equals(args[1]))) ||
                !("com.tencent.mm".equals(args[0]) || "com.eg.android.AlipayGphone".equals(args[0]))) {
            System.exit(1);
            return;
        }
        Thread.setDefaultUncaughtExceptionHandler((thread, failure) -> {
            System.out.println("BEECOUNT_ROOT_ERROR:callback");
            System.out.flush();
            System.exit(2);
        });
        // app_process 不会像 ActivityThread 一样初始化主 Looper；系统的
        // AccessibilityInteractionClient 在连接回调中需要它创建 Handler。
        if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
        HandlerThread thread = new HandlerThread("beecount-root-reader");
        thread.start();
        UiAutomation automation = null;
        int exitCode = 0;
        String phase = "connection";
        try {
            Class<?> connectionType = Class.forName("android.app.IUiAutomationConnection");
            Constructor<?> connectionConstructor = Class.forName("android.app.UiAutomationConnection")
                    .getDeclaredConstructor();
            connectionConstructor.setAccessible(true);
            Object connection = connectionConstructor.newInstance();
            phase = "constructor";
            Constructor<UiAutomation> constructor = UiAutomation.class.getDeclaredConstructor(
                    Looper.class, connectionType);
            constructor.setAccessible(true);
            automation = constructor.newInstance(thread.getLooper(), connection);
            phase = "connect";
            // 系统 uiautomator dump 默认会抑制已有无障碍服务，此入口明确保留它们。
            UiAutomation.class.getDeclaredMethod("connect", int.class).invoke(automation,
                    UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            phase = "read";
            JSONArray nodes = new JSONArray();
            // 能力探测只建立/释放连接，不读取任何前台页面。
            AccessibilityNodeInfo root = args.length == 2 ? null : automation.getRootInActiveWindow();
            if (root != null) {
                try { visit(root, args[0], nodes, 0); } finally { recycle(root); }
            }
            System.out.println(args.length == 2 ? "BEECOUNT_ROOT_READY" : "BEECOUNT_ROOT_NODES:" + nodes);
        } catch (Throwable failure) {
            // 私有 API 不兼容时失败退出，不输出页面、参数或堆栈到系统日志。
            Throwable cause = failure;
            boolean busy = false;
            for (int i = 0; i < 6 && cause != null; i++, cause = cause.getCause()) {
                if (cause instanceof IllegalStateException && cause.getMessage() != null &&
                        cause.getMessage().contains("already registered")) busy = true;
            }
            System.out.println("BEECOUNT_ROOT_ERROR:" + (busy ? "busy" : phase));
            exitCode = 2;
        } finally {
            try {
                if (automation != null) UiAutomation.class.getDeclaredMethod("disconnect")
                        .invoke(automation);
            } catch (Throwable ignored) { }
            thread.quitSafely();
        }
        System.exit(exitCode);
    }

    private static void visit(AccessibilityNodeInfo node, String target, JSONArray output, int depth) {
        if (depth > 32 || output.length() >= 512 || node.getPackageName() == null ||
                !target.contentEquals(node.getPackageName()) || node.isPassword()) return;
        String text = value(node.getText());
        String description = value(node.getContentDescription());
        append(output, text);
        if (!description.equals(text)) append(output, description);
        for (int i = 0; i < Math.min(node.getChildCount(), 128) && output.length() < 512; i++) {
            AccessibilityNodeInfo child = node.getChild(i);
            if (child == null) continue;
            try { visit(child, target, output, depth + 1); } finally { recycle(child); }
        }
    }

    private static String value(CharSequence value) {
        return value == null ? "" : value.toString().trim();
    }

    private static void append(JSONArray output, String text) {
        if (!text.isEmpty() && text.length() <= 256 && output.length() < 512) output.put(text);
    }

    @SuppressWarnings("deprecation")
    private static void recycle(AccessibilityNodeInfo node) { node.recycle(); }
}
