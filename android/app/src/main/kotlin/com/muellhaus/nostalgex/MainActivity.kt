package com.muellhaus.nostalgex

import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.LaunchedEffect
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
            // ScreenAwakePolicy: a load the viewer is sitting in front of keeps the TV awake, so a
            // long first load can't end in a sleeping TV. Playback holds it through the player's
            // own view (WatchScreen), so neither can release the other's hold; a refresh behind
            // the guide never shows these screens.
            val loading = model.screen is Screen.Loading || model.screen is Screen.LibraryLoad
            LaunchedEffect(loading) {
                if (loading) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            when (val s = model.screen) {
                is Screen.SignIn, is Screen.Connect, is Screen.ChooseServers, is Screen.ChooseLibraries -> ConnectScreen(model)
                is Screen.Loading -> LoadingScreen(s)
                is Screen.LibraryLoad -> LibraryLoadScreen(model, s)
                Screen.UnfinishedLoads -> UnfinishedLoadsScreen(model)
                is Screen.Failed -> ConnectionFailedScreen(model, s.message)
                Screen.NoChannels -> NoChannelsScreen(model)
                Screen.Watching -> WatchScreen(model)
            }
        }
        model.start()
        model.openLink(intent?.dataString)
    }

    /**
     * Every remote press, before any screen sees it, restarts GUIDE TIMEOUT's wait (#290).
     * `Activity.dispatchKeyEvent` calls this for each key event before dispatching it; overriding
     * `dispatchKeyEvent` itself means calling androidx's restricted `ComponentActivity` override.
     */
    override fun onUserInteraction() {
        super.onUserInteraction()
        if (::model.isInitialized) model.noteRemoteActivity()
    }

    /** A link while the app runs (singleTask): tunes now, or once the guide is up. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        model.openLink(intent.dataString)
    }

    override fun onStop() {
        super.onStop()
        // Leaving the app stops playback (and any transcode), ends the server's session and puts
        // its watch state back (PlaybackTracker.onBackground); coming back tunes in again.
        model.watchReporter.stop()
        model.playback.stop()
        // The daily refresh waits too: nobody is watching the guide it would rebuild.
        model.stopDailyRefresh()
    }

    override fun onRestart() {
        super.onRestart()
        model.channel?.let(model::tune)
        model.startDailyRefresh()
    }

    override fun onDestroy() {
        super.onDestroy()
        model.release()
    }
}
