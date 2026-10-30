package com.muellhaus.nostalgex.ui

import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import androidx.compose.foundation.layout.size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.sp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.muellhaus.nostalgex.R

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

internal fun qrBitmap(text: String, size: Int): Bitmap {
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 2))
    val pixels = IntArray(size * size) { i -> if (matrix[i % size, i / size]) AndroidColor.BLACK else AndroidColor.WHITE }
    return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888)
}
