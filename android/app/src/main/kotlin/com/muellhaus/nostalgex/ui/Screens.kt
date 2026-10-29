package com.muellhaus.nostalgex.ui

import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.tv.material3.ClickableSurfaceDefaults
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.muellhaus.nostalgex.R
import com.muellhaus.nostalgex.Screen

val VT323 = FontFamily(Font(R.font.vt323))
val DMMono = FontFamily(Font(R.font.dmmono_regular))
val DMMonoMedium = FontFamily(Font(R.font.dmmono_medium))

object Palette {
    val ink = Color.White
    val dim = Color.White.copy(alpha = 0.6f)
    val faint = Color.White.copy(alpha = 0.3f)
    val guideBg = Color(0xE6000814)
    val rowBg = Color(0xFF0B1E5B)
    val rowFocus = Color(0xFFFFE500)
    val accent = Color(0xFFFFE500)
}

fun retro(size: Int, color: Color = Palette.ink) = TextStyle(fontFamily = VT323, fontSize = size.sp, color = color)
fun mono(size: Int, color: Color = Palette.ink, medium: Boolean = false) =
    TextStyle(fontFamily = if (medium) DMMonoMedium else DMMono, fontSize = size.sp, color = color)

@Composable
private fun Centered(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
            content()
        }
    }
}

@Composable
private fun Wordmark() {
    Image(painterResource(R.drawable.wordmark), contentDescription = "Nostalgex", modifier = Modifier.width(360.dp))
}

/** The Apple TV's sign-in (SettingsView.swift): the code, plex.tv/link, and a QR with the code in it. */
@Composable
fun SignInScreen(state: Screen.SignIn) {
    Centered {
        Wordmark()
        Spacer(Modifier.height(16.dp))
        if (state.error != null) {
            Text(state.error, style = mono(18, Palette.accent))
        }
        val pin = state.pin
        if (pin == null) {
            Text("CONNECTING TO PLEX…", style = retro(32, Palette.dim))
        } else {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(48.dp)) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("GO TO plex.tv/link AND ENTER:", style = mono(20, Palette.dim))
                    Spacer(Modifier.height(12.dp))
                    Text(pin.code, style = retro(96, Palette.accent))
                    Spacer(Modifier.height(12.dp))
                    Text("WAITING FOR AUTHORIZATION", style = mono(16, Palette.faint))
                }
                val qr = remember(pin.code) { qrBitmap("https://www.plex.tv/link/?pin=${pin.code}", 400) }
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Image(qr.asImageBitmap(), contentDescription = "QR code for plex.tv/link", modifier = Modifier.size(200.dp))
                    Spacer(Modifier.height(8.dp))
                    Text("SCAN TO CONNECT", style = mono(14, Palette.dim))
                }
            }
        }
    }
}

@Composable
fun LoadingScreen(state: Screen.Loading) {
    Centered {
        Wordmark()
        Spacer(Modifier.height(24.dp))
        Text(state.headline, style = retro(36))
        Text(state.detail, style = mono(16, Palette.dim), textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 96.dp))
    }
}

private fun qrBitmap(text: String, size: Int): Bitmap {
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 2))
    val pixels = IntArray(size * size) { i -> if (matrix[i % size, i / size]) AndroidColor.BLACK else AndroidColor.WHITE }
    return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888)
}
