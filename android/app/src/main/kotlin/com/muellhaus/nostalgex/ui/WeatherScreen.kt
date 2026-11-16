package com.muellhaus.nostalgex.ui

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalContext
import com.muellhaus.nostalgex.AppModel
import com.muellhaus.nostalgex.engine.GuideTextSize
import com.muellhaus.nostalgex.weather.WeatherPainter
import kotlinx.coroutines.delay

/**
 * LOCAL WEATHER's picture (I-016): the four screens on the 65 second wall-clock loop, drawn by [WeatherPainter] into whatever box it is
 * given (the tuner's 4:3 picture, or the whole screen), letterboxed. It redraws only as often as the picture moves.
 */
@Composable
internal fun WeatherScreen(model: AppModel, modifier: Modifier = Modifier) {
    val painter = remember { WeatherPainter(model.appContext) }
    val wx = model.weather
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            now = System.currentTimeMillis()
            delay(painter.nextDelay(now))
        }
    }
    // GUIDE TEXT SIZE: LARGER grows the text and never the layout; SMALLER and DEFAULT are the one size the screens are laid out for.
    val scale = if (model.guideTextSize == GuideTextSize.LARGE) 1.16f else 1f
    Canvas(modifier) {
        val frame = WeatherPainter.Frame(now, wx.place, wx.units, scale, wx.status, wx.model, wx.radar)
        drawIntoCanvas { painter.render(it.nativeCanvas, size.width, size.height, frame) }
    }
}
