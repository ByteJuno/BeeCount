package com.tntlikely.beecount

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RootWindowPolicyTest {
    @Test fun recognizesWalletResults() {
        assertTrue(RootWindowPolicy.supports("com.tencent.mm", "com.tencent.mm.plugin.wallet_core.ui.WalletOrderInfoNewUI"))
        assertTrue(RootWindowPolicy.supports("com.eg.android.AlipayGphone", "com.alipay.mobile.nebulacore.ui.H5Activity"))
    }

    @Test fun skipsChatsHomeAndUnrelatedApps() {
        assertFalse(RootWindowPolicy.supports("com.tencent.mm", "com.tencent.mm.ui.LauncherUI"))
        assertFalse(RootWindowPolicy.supports("com.tencent.mm", "com.tencent.mm.ui.chatting.ChattingUI"))
        assertFalse(RootWindowPolicy.supports("com.eg.android.AlipayGphone", "com.alipay.mobile.quinox.LauncherActivity"))
        assertFalse(RootWindowPolicy.supports("com.eg.android.AlipayGphone", "com.alipay.mobile.pay.ui.HomeActivity"))
        assertFalse(RootWindowPolicy.supports("com.example.fake", "WalletPayUI"))
    }

    @Test fun parsesFocusedWindowAndNeverFallsBackToCoveredApps() {
        assertEquals("com.tencent.mm", RootWindowPolicy.focus(
            "mCurrentFocus=Window{abc u0 com.tencent.mm/.plugin.wallet_core.ui.WalletOrderInfoNewUI}")?.first)
        assertNull(RootWindowPolicy.focus(
            "mCurrentFocus=Window{abc u0 Sys2038:com.example.overlay/.Dialog}\n" +
                "mFocusedApp=ActivityRecord{abc com.tencent.mm/.plugin.wallet_core.ui.WalletOrderInfoNewUI}"))
    }
}
