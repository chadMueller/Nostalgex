package com.muellhaus.nostalgex.ui

import android.view.KeyEvent as AndroidKeyEvent
import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type

/**
 * The remote's Back, while `enabled`, runs `action` instead of leaving the app, on every Android.
 *
 * Up to Android 15 Back arrives as KEYCODE_BACK, acted on at release so the release can't reach
 * the next screen. On Android 16 an app targeting API 36 gets predictive back: the key is never
 * sent to it, Back goes to the OnBackPressedDispatcher, and with nothing registered there the
 * activity finishes. So Back is also registered there. Only one of the two ever fires, because a
 * key this consumes never reaches the dispatcher.
 */
@Composable
fun Modifier.onBack(enabled: Boolean, action: () -> Unit): Modifier {
    BackHandler(enabled) { action() }
    return onPreviewKeyEvent { e ->
        if (!enabled || e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_BACK) return@onPreviewKeyEvent false
        if (e.type == KeyEventType.KeyUp) action()
        true
    }
}
