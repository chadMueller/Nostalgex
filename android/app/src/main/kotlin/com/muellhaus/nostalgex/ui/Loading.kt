package com.muellhaus.nostalgex.ui

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextAlign
import androidx.tv.material3.Text
import com.muellhaus.nostalgex.AppModel
import com.muellhaus.nostalgex.LoadPhase
import com.muellhaus.nostalgex.R
import com.muellhaus.nostalgex.Screen
import kotlinx.coroutines.delay

/** Design units over black, as the other full screens. */
@Composable
private fun FullScreenFrame(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        CompositionLocalProvider(LocalUnit provides maxWidth / 1920f) {
            Box(modifier.fillMaxSize(), contentAlignment = Alignment.Center) { content() }
        }
    }
}

/** Dots that count up every 0.4 s, as LoadingView's timer. */
@Composable
private fun dots(): Int {
    var n by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(400)
            n = (n + 1) % 4
        }
    }
    return n
}

/**
 * A short wait. With nothing to report (LoadingScreenMode.splash) it is the logo and a
 * heartbeat; otherwise the headline and its detail.
 */
@Composable
fun LoadingScreen(state: Screen.Loading) = FullScreenFrame {
    val n = dots()
    if (state.headline.isEmpty()) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(26))) {
            Image(painterResource(R.drawable.wordmark), contentDescription = "Nostalgex", modifier = Modifier.width(u(460)))
            Text("■■■", style = font(DMMonoMedium, 14, BrandCyan.copy(alpha = 0.25f + 0.25f * n), tracking = 10))
        }
    } else {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(28))) {
            Image(painterResource(R.drawable.wordmark), contentDescription = "Nostalgex", modifier = Modifier.width(u(500)).padding(bottom = u(20)))
            Text(state.headline + ".".repeat(n), style = font(DMMonoMedium, 32, BrandCyan), textAlign = TextAlign.Center)
            if (state.detail.isNotEmpty()) {
                Text(state.detail, style = font(DMMono, 22, Color.White.copy(alpha = 0.45f)), textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = u(720)))
            }
        }
    }
}

/** LoadingView's full load: the step rail, the headline, its detail, the progress, and START OVER. */
@Composable
fun LibraryLoadScreen(model: AppModel, state: Screen.LibraryLoad) {
    var confirming by remember { mutableStateOf(false) }
    FullScreenFrame(
        Modifier.onPreviewKeyEvent { e ->
            // Back closes the question first, as the alert's cancel.
            if (!confirming || e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_BACK) return@onPreviewKeyEvent false
            if (e.type == KeyEventType.KeyUp) confirming = false
            true
        },
    ) {
        val n = dots()
        Column(
            Modifier.padding(vertical = u(40)),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(u(28)),
        ) {
            Image(painterResource(R.drawable.wordmark), contentDescription = "Nostalgex", modifier = Modifier.width(u(500)).padding(bottom = u(20)))
            if (state.firstRun) {
                Text(
                    "First setup can take a few minutes to scan and build channels.",
                    style = font(DMMono, 22, Color.White.copy(alpha = 0.55f)), maxLines = 1,
                    modifier = Modifier.padding(horizontal = u(40)),
                )
            }
            StepRail(state.phase, Modifier.padding(horizontal = u(48)))
            Text(state.headline + ".".repeat(n), style = font(DMMonoMedium, 32, BrandCyan), textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = u(800)))
            if (state.detail.isNotEmpty()) {
                Text(state.detail, style = font(DMMono, 22, Color.White.copy(alpha = 0.45f)), textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = u(720)))
            }
            state.progress?.let { p ->
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(10))) {
                    Box(Modifier.width(u(420)).height(u(4)).clip(RoundedCornerShape(u(2))).background(Color.White.copy(alpha = 0.15f))) {
                        Box(Modifier.fillMaxWidth(p.coerceIn(0f, 1f)).height(u(4)).background(BrandCyan))
                    }
                    if (state.caption.isNotEmpty()) Text(state.caption.uppercase(), style = font(DMMono, 19, Color.White.copy(alpha = 0.4f)))
                }
            }
            // Always there while a load runs, behind a question: it is often the focused control.
            Box(Modifier.padding(top = u(8))) {
                if (!confirming) OnboardingButton("START OVER", primary = false, focusFirst = true, fontSize = 20) { confirming = true }
            }
        }
        if (confirming) StartOverQuestion(model) { confirming = false }
    }
}

/** The alert in front of START OVER: KEEP LOADING is where focus starts. */
@Composable
private fun StartOverQuestion(model: AppModel, onKeepLoading: () -> Unit) {
    val shape = RoundedCornerShape(u(18))
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.7f)), contentAlignment = Alignment.Center) {
        Column(
            Modifier
                .widthIn(max = u(900))
                .clip(shape)
                .background(Color(0xFF16161C))
                .border(u(1), Color.White.copy(alpha = 0.12f), shape)
                .padding(horizontal = u(64), vertical = u(48)),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(u(24)),
        ) {
            Text("Start over?", style = font(DMMonoMedium, 32, Color.White))
            val server = model.serverName.ifEmpty { "your server" }
            Text(
                "Stops loading and signs out of $server. You can sign in again right away.",
                style = font(DMMono, 22, Color.White.copy(alpha = 0.7f)), textAlign = TextAlign.Center,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(u(24)), modifier = Modifier.padding(top = u(8))) {
                OnboardingButton("KEEP LOADING", primary = true, focusFirst = true, fontSize = 24, onClick = onKeepLoading)
                OnboardingButton("START OVER", primary = false, fontSize = 24, onClick = model::startOver)
            }
        }
    }
}

/** LibraryLoadStepRail: a circle per step, a tick when done, a dot on the one running, joined by lines. */
@Composable
private fun StepRail(current: LoadPhase, modifier: Modifier = Modifier) {
    val steps = LoadPhase.entries
    Row(modifier.widthIn(max = u(900)), verticalAlignment = Alignment.Top) {
        for ((i, step) in steps.withIndex()) {
            val done = step.ordinal < current.ordinal
            val active = step == current
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(8))) {
                Box(
                    Modifier.size(u(28)).border(u(2), if (done || active) BrandCyan else Color.White.copy(alpha = 0.25f), CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    when {
                        done -> Text("✓", style = font(DMMonoMedium, 14, BrandCyan))
                        active -> Box(Modifier.size(u(10)).background(BrandCyan, CircleShape))
                    }
                }
                Text(
                    step.title.uppercase(), maxLines = 1,
                    style = font(DMMono, 16, when {
                        active -> BrandCyan
                        done -> Color.White.copy(alpha = 0.55f)
                        else -> Color.White.copy(alpha = 0.3f)
                    }),
                )
            }
            if (i < steps.size - 1) {
                Box(Modifier.padding(top = u(13)).width(u(36)).height(u(2)).background(if (done) BrandCyan.copy(alpha = 0.5f) else Color.White.copy(alpha = 0.15f)))
            }
        }
    }
}

/** UnfinishedLoadsView: the last two loads never finished, so the app asks before a third. */
@Composable
fun UnfinishedLoadsScreen(model: AppModel) = FullScreenFrame {
    Column(Modifier.padding(u(48)), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(32))) {
        Image(painterResource(R.drawable.wordmark), contentDescription = "Nostalgex", modifier = Modifier.width(u(540)))
        Text("LOADING DIDN'T FINISH", style = font(DMMonoMedium, 28, Color.White.copy(alpha = 0.8f)))
        Text(
            "The last two times, Nostalgex closed before your library finished loading.\nTry again, or start over to sign in again or pick a different server.",
            style = font(DMMono, 18, Color.White.copy(alpha = 0.5f)), textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(max = u(1100)),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(u(24))) {
            OnboardingButton("TRY AGAIN", primary = true, focusFirst = true, fontSize = 24, onClick = model::tryLoadingAgain)
            OnboardingButton("START OVER", primary = false, fontSize = 24, onClick = model::startOver)
        }
    }
}
