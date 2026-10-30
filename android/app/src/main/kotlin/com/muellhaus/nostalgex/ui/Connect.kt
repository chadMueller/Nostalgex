package com.muellhaus.nostalgex.ui

import android.view.KeyEvent as AndroidKeyEvent
import androidx.compose.foundation.Image
import com.muellhaus.nostalgex.engine.LibrarySection
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.focusable
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.tv.material3.Text
import com.muellhaus.nostalgex.AppModel
import com.muellhaus.nostalgex.ConnectStep
import com.muellhaus.nostalgex.Discovery
import com.muellhaus.nostalgex.R
import com.muellhaus.nostalgex.Screen
import com.muellhaus.nostalgex.mediabrowser.CheckedServer
import com.muellhaus.nostalgex.mediabrowser.MediaBrowserClient
import com.muellhaus.nostalgex.mediabrowser.PublicUser
import kotlinx.coroutines.delay

private val Warning = Color(0xFFFFB020)
private val ErrorRed = Color(0xFFFF2244)

/**
 * The connect screens (SettingsView.swift): branding on the left, controls on the right. The
 * picker offers Plex first, then Jellyfin and Emby, which find the server on the network or take
 * a typed address, check it, and sign in the shortest way it allows (Quick Connect when the
 * server has it on, else a user tile or a name and password).
 */
@Composable
fun ConnectScreen(model: AppModel) {
    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        CompositionLocalProvider(LocalUnit provides maxWidth / 1920f) {
            Row(
                Modifier
                    .fillMaxSize()
                    .onPreviewKeyEvent { e ->
                        if (e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_BACK) return@onPreviewKeyEvent false
                        // The picker is the first screen: Back there leaves the app.
                        if (!model.connectCanGoBack) return@onPreviewKeyEvent false
                        if (e.type == KeyEventType.KeyUp) model.connectBack()
                        true
                    }
                    .padding(horizontal = u(100), vertical = u(60)),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(u(80)),
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(u(28))) {
                    Image(painterResource(R.drawable.wordmark), contentDescription = "Nostalgex", modifier = Modifier.widthIn(max = u(440)))
                    if (model.screen is Screen.ChooseLibraries) {
                        Text("CHOOSE YOUR LIBRARIES", style = font(DMMonoMedium, 40, Color.White.copy(alpha = 0.9f)))
                        Text(
                            "Pick which of your ${model.backendName} libraries Nostalgex should build channels from. A library you leave off is never scanned. You can change this later in Settings.",
                            style = font(DMMono, 22, Color.White.copy(alpha = 0.45f)),
                            modifier = Modifier.widthIn(max = u(560)),
                        )
                    } else {
                        Text("CONNECT YOUR SERVER", style = font(DMMonoMedium, 40, Color.White.copy(alpha = 0.9f)))
                        Text(
                            "Nostalgex builds a retro channel guide from your own library. Connect Plex, Jellyfin, or Emby to get started.",
                            style = font(DMMono, 22, Color.White.copy(alpha = 0.45f)),
                            modifier = Modifier.widthIn(max = u(560)),
                        )
                        Text(model.versionLabel, style = font(DMMono, 15, Color.White.copy(alpha = 0.25f)))
                    }
                }
                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                    when (val s = model.screen) {
                        is Screen.SignIn -> key("plex") { PlexCode(model, s) }
                        is Screen.Connect -> key(s.step::class, (s.step as? ConnectStep.Find)?.discovery?.let { it::class }) { Step(model, s) }
                        is Screen.ChooseLibraries -> key("libraries") { ChooseLibraries(model, s.sections) }
                        else -> {}
                    }
                }
            }
        }
    }
}

@Composable
private fun Step(model: AppModel, s: Screen.Connect) {
    when (val step = s.step) {
        ConnectStep.Picker -> Picker(model, s.error)
        is ConnectStep.Find -> Find(model, step, s.message)
        is ConnectStep.TypeAddress -> TypeAddress(model, step.kind, s.message)
        is ConnectStep.Checking -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(28))) {
            Waiting("CONNECTING TO ${step.label.uppercase()}")
            QuietButton("CANCEL", focusFirst = true) { model.backToFind(step.kind) }
        }
        is ConnectStep.SignIn -> SignIn(model, step.server, s.message, s.error)
        is ConnectStep.QuickConnect -> QuickConnect(model, step.server, step.code)
        is ConnectStep.SigningIn -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(28))) {
            Waiting("SIGNING IN")
            QuietButton("CANCEL", focusFirst = true) { model.usePassword(step.server) }
        }
    }
}

@Composable
private fun Picker(model: AppModel, error: String?) {
    Column(Modifier.widthIn(max = u(600)), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(22))) {
        if (error != null) Text(error.uppercase(), style = font(DMMonoMedium, 26, ErrorRed), textAlign = TextAlign.Center)
        OnboardingButton("CONNECT TO PLEX", primary = true, focusFirst = true, fontSize = 34, fullWidth = true, onClick = model::signIn)
        Text("OR CONNECT WITH", style = font(DMMono, 20, Color.White.copy(alpha = 0.35f), tracking = 2), modifier = Modifier.padding(top = u(10)))
        OnboardingButton("JELLYFIN", primary = false, fontSize = 28, fullWidth = true) { model.connectTo("jellyfin") }
        OnboardingButton("EMBY", primary = false, fontSize = 28, fullWidth = true) { model.connectTo("emby") }
    }
}

@Composable
private fun Find(model: AppModel, step: ConnectStep.Find, message: String?) {
    val name = MediaBrowserClient.displayName(step.kind)
    val searching = step.discovery == Discovery.Searching
    Column(Modifier.widthIn(max = u(720)), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(22))) {
        StepTitle("CONNECT TO ${name.uppercase()}")
        Text(
            "Nostalgex can look for your $name server on this network. Or type its address.",
            style = font(DMMono, 22, Color.White.copy(alpha = 0.5f)), textAlign = TextAlign.Center,
        )
        if (message != null) WarningText(message)
        val several = step.discovery as? Discovery.Several
        if (several != null) {
            Caption("PICK YOUR SERVER")
            for ((i, server) in several.servers.withIndex()) {
                OnboardingButton("${server.name}  ${server.address}", primary = false, focusFirst = i == 0, fontSize = 24, fullWidth = true) {
                    model.checkServer(step.kind, server.address, server.name)
                }
            }
        }
        if (step.discovery == Discovery.NothingFound) {
            WarningText("No server answered. Check the TV and the server are on the same network, or type its address.")
        }
        OnboardingButton(
            when (step.discovery) {
                Discovery.Searching -> "SEARCHING..."
                Discovery.Idle -> "FIND MY SERVER"
                else -> "SEARCH AGAIN"
            },
            primary = step.discovery == Discovery.Idle || searching,
            focusFirst = step.discovery == Discovery.Idle || searching,
            fontSize = if (step.discovery == Discovery.Idle || searching) 34 else 28,
            fullWidth = true,
        ) { if (!searching) model.findServers(step.kind) }
        OnboardingButton(
            "TYPE AN ADDRESS", primary = false, focusFirst = step.discovery == Discovery.NothingFound, fontSize = 28, fullWidth = true,
        ) { model.typeAddress(step.kind) }
        QuietButton("BACK", modifier = Modifier.padding(top = u(6))) { model.showPicker() }
    }
}

@Composable
private fun TypeAddress(model: AppModel, kind: String, message: String?) {
    var address by remember { mutableStateOf(model.lastAddress) }
    val connect = remember { FocusRequester() }
    Column(Modifier.widthIn(max = u(720)), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(24))) {
        StepTitle("CONNECT TO ${MediaBrowserClient.displayName(kind).uppercase()}")
        if (message != null) WarningText(message)
        Field("SERVER ADDRESS", address, placeholder = "192.168.1.10:8096", keyboard = KeyboardType.Uri, imeAction = ImeAction.Go, focusFirst = true, onChange = { address = it }) {
            model.lastAddress = address
            if (address.isNotBlank()) model.checkServer(kind, address, address.trim())
        }
        Text("The address and port, like 192.168.1.10:8096", style = font(DMMono, 19, Color.White.copy(alpha = 0.4f)))
        OnboardingButton("CONNECT", primary = true, fontSize = 34, fullWidth = true, requester = connect) {
            model.lastAddress = address
            if (address.isNotBlank()) model.checkServer(kind, address, address.trim())
        }
        QuietButton("BACK", modifier = Modifier.padding(top = u(6))) { model.backToFind(kind) }
    }
}

@Composable
private fun SignIn(model: AppModel, server: CheckedServer, message: String?, error: String?) {
    var username by remember { mutableStateOf(model.lastUsername) }
    var password by remember { mutableStateOf("") }
    var picked by remember { mutableStateOf<PublicUser?>(null) }
    var typingName by remember { mutableStateOf(false) }
    val passwordField = remember { FocusRequester() }
    // Decided once, as the screen opens: a name already there (a wrong password) starts on the password.
    val startOnPassword = remember { username.isNotEmpty() }
    val showTiles = server.users.isNotEmpty() && !typingName
    val signIn = { model.signInWithPassword(server, picked?.name ?: username, password) }
    // A tile with a password moves to the field for it.
    LaunchedEffect(picked) { if (picked?.hasPassword == true) runCatching { passwordField.requestFocus() } }
    Column(Modifier.widthIn(max = u(720)), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(20))) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(6))) {
            Caption("SIGN IN TO")
            Text(server.name.uppercase(), style = font(DMMonoMedium, 34, BrandCyan), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("${MediaBrowserClient.displayName(server.kind).uppercase()}  ${server.url}", style = font(DMMono, 18, Color.White.copy(alpha = 0.35f)), maxLines = 1)
        }
        if (message != null) Text(message, style = font(DMMono, 19, Color.White.copy(alpha = 0.55f)), textAlign = TextAlign.Center)
        if (error != null) Text(error.uppercase(), style = font(DMMonoMedium, 22, ErrorRed), textAlign = TextAlign.Center)

        if (showTiles) {
            Caption("WHO'S WATCHING?")
            // Three to a row, then SOMEONE ELSE. No password signs in on the press.
            val tiles: List<PublicUser?> = server.users.take(8) + listOf(null)
            Column(verticalArrangement = Arrangement.spacedBy(u(16))) {
                for ((r, row) in tiles.chunked(3).withIndex()) {
                    Row(horizontalArrangement = Arrangement.spacedBy(u(16))) {
                        for ((c, user) in row.withIndex()) {
                            Box(Modifier.weight(1f)) {
                                if (user != null) {
                                    OnboardingButton(user.name, primary = picked == user, focusFirst = r == 0 && c == 0, fontSize = 26, fullWidth = true) {
                                        picked = user
                                        username = user.name
                                        password = ""
                                        if (!user.hasPassword) model.signInWithPassword(server, user.name, "")
                                    }
                                } else {
                                    OnboardingButton("SOMEONE ELSE", primary = false, fontSize = 22, fullWidth = true) {
                                        picked = null
                                        typingName = true
                                        username = ""
                                    }
                                }
                            }
                        }
                        // Keep the last row's tiles the same width as the others.
                        repeat(3 - row.size) { Box(Modifier.weight(1f)) }
                    }
                }
            }
        } else {
            // A name already there (a wrong password) puts focus on the password.
            Field("USERNAME", username, focusFirst = !startOnPassword, onChange = { username = it; model.lastUsername = it }) {
                runCatching { passwordField.requestFocus() }
            }
        }

        if (!showTiles || picked?.hasPassword == true) {
            Field(
                picked?.let { "PASSWORD FOR ${it.name.uppercase()}" } ?: "PASSWORD",
                password, secure = true, imeAction = ImeAction.Go, focusFirst = !showTiles && startOnPassword, requester = passwordField, onChange = { password = it },
            ) { signIn() }
            OnboardingButton("SIGN IN", primary = true, fontSize = 34, fullWidth = true) { signIn() }
        }
        if (server.offersQuickConnect) {
            OnboardingButton("USE QUICK CONNECT", primary = false, fontSize = 28, fullWidth = true) { model.startQuickConnect(server) }
        }
        QuietButton("BACK", modifier = Modifier.padding(top = u(6))) { model.backToFind(server.kind) }
    }
}

@Composable
private fun QuickConnect(model: AppModel, server: CheckedServer, code: String?) {
    Column(Modifier.widthIn(max = u(760)), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(22))) {
        StepTitle("APPROVE THIS TV IN JELLYFIN")
        Text(
            "On your phone or computer, open Jellyfin, then your profile, then Quick Connect, and enter this code.",
            style = font(DMMono, 22, Color.White.copy(alpha = 0.6f)), textAlign = TextAlign.Center,
        )
        Text(code ?: "------", style = font(DMMonoMedium, 108, Color.White, tracking = 16))
        Waiting("WAITING FOR APPROVAL")
        Text("${server.name.uppercase()}  ${server.url}", style = font(DMMono, 18, Color.White.copy(alpha = 0.35f)), maxLines = 1)
        // The code is the thing to look at, so these buttons glow rather than fill.
        OnboardingButton("SIGN IN WITH A PASSWORD", primary = false, focusFirst = true, fontSize = 28, fullWidth = true, quietFocus = true) {
            model.usePassword(server)
        }
        QuietButton("BACK", quietFocus = true, modifier = Modifier.padding(top = u(6))) { model.backToFind(server.kind) }
    }
}

/**
 * LibrarySelectionView: one row per library, every one on to start, so the remote starts on
 * CONTINUE and one press builds the full guide. The server's name shows only when there are
 * libraries from more than one.
 */
@Composable
private fun ChooseLibraries(model: AppModel, sections: List<LibrarySection>) {
    var included by remember { mutableStateOf(sections.map { it.id }.toSet()) }
    val multiServer = sections.map { it.serverId }.toSet().size > 1
    Column(Modifier.widthIn(max = u(760)), verticalArrangement = Arrangement.spacedBy(u(24))) {
        Column(
            Modifier.heightIn(max = u(560)).verticalScroll(rememberScrollState()).padding(vertical = u(12)),
            verticalArrangement = Arrangement.spacedBy(u(12)),
        ) {
            for (section in sections) {
                val on = section.id in included
                LibraryRow(section.title, if (multiServer) "${section.serverName} · ${section.typeLabel}" else section.typeLabel, on) {
                    included = if (on) included - section.id else included + section.id
                }
            }
        }
        Box(Modifier.graphicsLayer { alpha = if (included.isEmpty()) 0.35f else 1f }) {
            OnboardingButton("CONTINUE", primary = true, focusFirst = true, fontSize = 34, fullWidth = true) { model.confirmLibraries(included) }
        }
    }
}

/** A library-selection row: the picker rows' cyan slab when focused, INCLUDED or OFF on the right. */
@Composable
private fun LibraryRow(title: String, subtitle: String, on: Boolean, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(u(14))
    val onFocus = Color(0f, 0.06f, 0.09f)
    Row(
        Modifier
            .fillMaxWidth()
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .onKeyEvent { e ->
                if (e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_DPAD_CENTER && e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_ENTER) return@onKeyEvent false
                if (e.type == KeyEventType.KeyUp) onClick()
                true
            }
            .graphicsLayer { scaleX = if (focused) 1.04f else 1f; scaleY = scaleX }
            .clip(shape)
            .background(if (focused) BrandCyan else Color.White.copy(alpha = 0.03f))
            .then(if (focused) Modifier else Modifier.border(u(1.5), Color.White.copy(alpha = 0.18f), shape))
            .padding(horizontal = u(32), vertical = u(24)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(u(6))) {
            Text(title, style = font(DMMonoMedium, 28, if (focused) onFocus else if (on) Color.White else Color.White.copy(alpha = 0.55f)), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, style = font(DMMono, 18, if (focused) onFocus.copy(alpha = 0.75f) else Color.White.copy(alpha = 0.4f)), maxLines = 1)
        }
        Text(if (on) "INCLUDED" else "OFF", style = font(DMMonoMedium, 22, if (focused) onFocus else if (on) BrandCyan else Color.White.copy(alpha = 0.35f)))
    }
}

/** Plex's code (pinDisplaySection): plex.tv/link and the code, and a QR with the code in it. */
@Composable
private fun PlexCode(model: AppModel, s: Screen.SignIn) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(u(80))) {
        Column(verticalArrangement = Arrangement.spacedBy(u(24))) {
            Text("GO TO plex.tv/link AND ENTER:", style = font(DMMonoMedium, 28, BrandCyan))
            Text(s.pin?.code ?: "----", style = font(DMMonoMedium, 108, Color.White, tracking = 16))
            if (s.error != null) Text(s.error, style = font(DMMonoMedium, 22, ErrorRed))
            else Waiting(if (s.pin == null) "CONNECTING TO PLEX.TV" else "WAITING FOR AUTHORIZATION")
            QuietButton("CANCEL", focusFirst = true, quietFocus = true) { model.showPicker() }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(u(12))) {
            val url = s.pin?.let { "https://www.plex.tv/link/?pin=${it.code}" } ?: "https://www.plex.tv/link/"
            val qr = remember(url) { qrBitmap(url, 400) }
            Image(qr.asImageBitmap(), contentDescription = "QR code for plex.tv/link", modifier = Modifier.size(u(200)).clip(RoundedCornerShape(u(8))))
            Text("SCAN TO CONNECT", style = font(DMMono, 20, Color.Gray.copy(alpha = 0.6f)))
        }
    }
}

// ── Pieces ───────────────────────────────────────────────────────────────

@Composable
private fun StepTitle(text: String) = Text(text, style = font(DMMonoMedium, 34, BrandCyan), textAlign = TextAlign.Center)

@Composable
private fun Caption(text: String) = Text(text, style = font(DMMonoMedium, 20, Color.White.copy(alpha = 0.45f), tracking = 2))

@Composable
private fun WarningText(text: String) =
    Text(text, style = font(DMMono, 20, Warning.copy(alpha = 0.95f)), textAlign = TextAlign.Center)

/** WaitingIndicatorView: the message with dots that count up every half second. */
@Composable
private fun Waiting(message: String) {
    var dots by remember { mutableStateOf("") }
    LaunchedEffect(Unit) {
        while (true) {
            delay(500)
            dots = if (dots.length >= 3) "" else "$dots."
        }
    }
    Text(message + dots, style = font(DMMonoMedium, 24, Color(0xFF00C4FF)), textAlign = TextAlign.Center)
}

/** The quiet role: a capsule that fills only when focused, for BACK and CANCEL. */
@Composable
private fun QuietButton(label: String, focusFirst: Boolean = false, quietFocus: Boolean = false, modifier: Modifier = Modifier, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val requester = remember { FocusRequester() }
    val shape = RoundedCornerShape(50)
    val slab = focused && !quietFocus
    Text(
        label,
        style = font(DMMonoMedium, 24, if (slab) Color(0f, 0.06f, 0.09f) else if (focused) Color.White else Color.White.copy(alpha = 0.42f), tracking = 1),
        modifier = modifier
            .focusRequester(requester)
            .onFocusChanged { focused = it.isFocused }
            .focusable()
            .onKeyEvent { e ->
                if (e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_DPAD_CENTER && e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_ENTER) return@onKeyEvent false
                if (e.type == KeyEventType.KeyUp) onClick()
                true
            }
            .clip(shape)
            .background(if (slab) BrandCyan else Color.Transparent)
            .then(if (focused && quietFocus) Modifier.border(u(3), BrandCyan, shape) else Modifier)
            .padding(horizontal = u(28), vertical = u(12)),
    )
    if (focusFirst) LaunchedEffect(Unit) { runCatching { requester.requestFocus() } }
}

/**
 * OnboardingField: a caption over a well. The well is a button until pressed, so moving
 * through the screen never opens the keyboard; the press opens it, and the keyboard's own
 * action (Next, Go, Done) moves on.
 */
@Composable
private fun Field(
    caption: String,
    text: String,
    placeholder: String = "Press to type",
    secure: Boolean = false,
    keyboard: KeyboardType = if (secure) KeyboardType.Password else KeyboardType.Text,
    /** The keyboard's return key: Next moves on, Go submits (submitLabel). */
    imeAction: ImeAction = ImeAction.Next,
    focusFirst: Boolean = false,
    requester: FocusRequester = remember { FocusRequester() },
    onChange: (String) -> Unit,
    onSubmit: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    // The keyboard has to be told to close. Left attached when its field goes away, Android
    // TV's keyboard stayed live but unseen and turned every OK press into the key it had
    // focused (a "q"), so the next screen's buttons ignored OK until an arrow was pressed.
    val keyboardController = LocalSoftwareKeyboardController.current
    var inputFocused by remember { mutableStateOf(false) }
    val input = remember { FocusRequester() }
    val shape = RoundedCornerShape(u(12))
    val shown = if (secure) "•".repeat(text.length) else text
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(u(10))) {
        Text(caption, style = font(DMMonoMedium, 20, if (focused || editing) BrandCyan else Color.White.copy(alpha = 0.45f), tracking = 2))
        val well = Modifier
            .fillMaxWidth()
            .height(u(76))
            .clip(shape)
            .background(if (focused || editing) Color(0.03f, 0.10f, 0.13f) else Color(0.06f, 0.06f, 0.06f))
            .border(if (focused || editing) u(3) else u(1.5), if (focused || editing) BrandCyan else Color.White.copy(alpha = 0.18f), shape)
            .padding(horizontal = u(24))
        if (editing) {
            BasicTextField(
                value = text,
                onValueChange = onChange,
                singleLine = true,
                textStyle = font(DMMono, 30, Color.White),
                cursorBrush = SolidColor(Color.White.copy(alpha = 0.9f)),
                visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
                keyboardOptions = KeyboardOptions(keyboardType = keyboard, imeAction = imeAction, autoCorrectEnabled = false),
                keyboardActions = KeyboardActions(onAny = {
                    keyboardController?.hide()
                    editing = false
                    onSubmit()
                }),
                modifier = well
                    .focusRequester(input)
                    .onFocusChanged {
                        // Called once on attach, unfocused: only leaving after focus ends editing.
                        if (it.isFocused) inputFocused = true
                        else if (inputFocused) {
                            inputFocused = false
                            keyboardController?.hide()
                            editing = false
                        }
                    },
                decorationBox = { inner -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.CenterStart) { inner() } },
            )
            LaunchedEffect(Unit) { runCatching { input.requestFocus() } }
            // A screen change while typing removes the field without a focus change.
            DisposableEffect(Unit) { onDispose { keyboardController?.hide() } }
        } else {
            Box(
                well
                    .focusRequester(requester)
                    .onFocusChanged { focused = it.isFocused }
                    .focusable()
                    .onKeyEvent { e ->
                        if (e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_DPAD_CENTER && e.key.nativeKeyCode != AndroidKeyEvent.KEYCODE_ENTER) return@onKeyEvent false
                        if (e.type == KeyEventType.KeyUp) editing = true
                        true
                    },
                contentAlignment = Alignment.CenterStart,
            ) {
                Text(
                    shown.ifEmpty { placeholder },
                    style = font(DMMono, 30, if (shown.isEmpty()) Color.White.copy(alpha = if (focused) 0.6f else 0.48f) else Color.White.copy(alpha = if (focused) 1f else 0.78f)),
                    maxLines = 1,
                )
            }
        }
    }
    if (focusFirst) LaunchedEffect(Unit) { runCatching { requester.requestFocus() } }
}
