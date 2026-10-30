package com.muellhaus.nostalgex

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.muellhaus.nostalgex.ui.LibraryLoadScreen
import com.muellhaus.nostalgex.ui.LoadingScreen
import com.muellhaus.nostalgex.ui.UnfinishedLoadsScreen
import com.muellhaus.nostalgex.ui.ConnectionFailedScreen
import com.muellhaus.nostalgex.ui.NoChannelsScreen
import com.muellhaus.nostalgex.ui.ConnectScreen
import com.muellhaus.nostalgex.ui.WatchScreen

class MainActivity : ComponentActivity() {
    private lateinit var model: AppModel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        model = AppModel(applicationContext)
        setContent {
            when (val s = model.screen) {
                is Screen.SignIn, is Screen.Connect, is Screen.ChooseLibraries -> ConnectScreen(model)
                is Screen.Loading -> LoadingScreen(s)
                is Screen.LibraryLoad -> LibraryLoadScreen(model, s)
                Screen.UnfinishedLoads -> UnfinishedLoadsScreen(model)
                is Screen.Failed -> ConnectionFailedScreen(model, s.message)
                Screen.NoChannels -> NoChannelsScreen(model)
                Screen.Watching -> WatchScreen(model)
            }
        }
        model.start()
    }

    override fun onStop() {
        super.onStop()
        // Leaving the app stops playback (and any transcode); coming back tunes in again.
        model.playback.stop()
    }

    override fun onRestart() {
        super.onRestart()
        model.channel?.let(model::tune)
    }

    override fun onDestroy() {
        super.onDestroy()
        model.release()
    }
}
