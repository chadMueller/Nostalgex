package com.muellhaus.nostalgex.ui

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.tv.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import com.muellhaus.nostalgex.AppModel
import com.muellhaus.nostalgex.engine.DesignTokens
import com.muellhaus.nostalgex.engine.RatingNudgePolicy
import kotlinx.coroutines.delay

/**
 * The "Enjoying Nostalgex?" banner below the guide (the Apple TV's RatingNudgeBanner): it takes focus when it appears,
 * landing on RATE so rating is one press. Any way out (NOT NOW, RATE, Up, Back, or 8 untouched seconds) dismisses it, and
 * the guide puts focus back on the live row. Moving between the two buttons counts as touching it and stops the timer.
 * Whether it may appear at all is [RatingNudgePolicy]'s call.
 */
@Composable
internal fun RatingNudgeBanner(model: AppModel, onDismissed: () -> Unit) {
    val rate = remember { FocusRequester() }
    var touched by remember { mutableStateOf(false) }
    var hasFocus by remember { mutableStateOf(false) }
    fun dismiss() { model.dismissRatingNudge(); onDismissed() }
    // The safe default: RATE. The banner slides in and the guide restores its own focus on the way back from full screen,
    // so ask again, at 0, 0.35 and 0.9 s, until it lands (the Apple TV's requestFocus).
    LaunchedEffect(Unit) {
        var waited = 0L
        for (at in listOf(0L, 350L, 900L)) {
            delay(at - waited); waited = at
            if (!hasFocus) runCatching { rate.requestFocus() }
        }
    }
    LaunchedEffect(touched) {
        if (!touched) { delay((RatingNudgePolicy.AUTO_DISMISS_SECONDS * 1000).toLong()); dismiss() }
    }
    val shape = RoundedCornerShape(u(12))
    Row(
        Modifier
            .widthIn(max = u(1240))
            .clip(shape)
            .background(Tokens.Panel.copy(alpha = 0.97f))
            .border(u(1.5f), Tokens.RestingOutline, shape)
            .onBack(true) { dismiss() }
            // Up is a no: the viewer is going back to the guide.
            .onPreviewKeyEvent { e ->
                if (e.key.nativeKeyCode == AndroidKeyEvent.KEYCODE_DPAD_UP) { if (e.type == KeyEventType.KeyDown) dismiss(); true } else false
            }
            .padding(horizontal = u(32), vertical = u(20)),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(u(32)),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(u(6))) {
            Text("Enjoying Nostalgex?", style = font(DMMonoMedium, DesignTokens.Size.BODY, Tokens.Text))
            Text("A star rating helps other people find it. Back brings you right here.", style = font(DMMono, DesignTokens.Size.CAPTION, Tokens.Text2))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(u(16))) {
            NudgeButton("RATE", Modifier.focusRequester(rate), onFocus = { hasFocus = it }, onMoved = { touched = true }) { model.rate(); onDismissed() }
            NudgeButton("NOT NOW", Modifier, onFocus = { hasFocus = it }, onMoved = { touched = true }) { dismiss() }
        }
    }
}

@Composable
private fun NudgeButton(label: String, modifier: Modifier, onFocus: (Boolean) -> Unit, onMoved: () -> Unit, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    var hadFocus by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(u(40))
    Box(
        modifier
            .onFocusChanged {
                // Focus moving from one button to the other is the viewer deciding: stop the clock.
                if (it.isFocused && hadFocus) onMoved()
                focused = it.isFocused
                onFocus(it.isFocused)
            }
            .focusable()
            .onKeyEvent { e ->
                when (e.key.nativeKeyCode) {
                    AndroidKeyEvent.KEYCODE_DPAD_CENTER, AndroidKeyEvent.KEYCODE_ENTER -> { if (e.type == KeyEventType.KeyUp) onClick(); true }
                    AndroidKeyEvent.KEYCODE_DPAD_LEFT, AndroidKeyEvent.KEYCODE_DPAD_RIGHT -> { if (e.type == KeyEventType.KeyDown) { onMoved(); hadFocus = true }; false }
                    else -> false
                }
            }
            .clip(shape)
            .background(if (focused) Tokens.SelectedRow else Tokens.Row)
            .border(u(if (focused) DesignTokens.Row.SELECTED_OUTLINE.toFloat() else DesignTokens.Row.RESTING_OUTLINE), if (focused) Tokens.Cyan else Tokens.RestingOutline, shape)
            .padding(horizontal = u(28), vertical = u(14)),
    ) {
        Text(label, style = font(DMMonoMedium, DesignTokens.Size.BODY, if (focused) Tokens.Text else Tokens.Text2), maxLines = 1)
    }
}
