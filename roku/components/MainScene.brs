' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Start-up: when this TV is already signed in, the saved guide goes up at
' once (LibraryTask, useCache) while sign-in is rechecked and the library is
' re-read in the background, as upstream shows its cached library first.
' Otherwise: sign in, pick the libraries when the account has more than one
' server (ServerPickerView), then load.

sub init()
    m.libraryBusy = false
    m.prompt = m.top.FindNode("prompt")
    m.hint = m.top.FindNode("hint")
    m.top.SetFocus(true)
    reg = NxPlexRegistry()
    kind = NxSignedInKind()
    if kind <> "plex" then
        ' Jellyfin or Emby: no account service to recheck; a rejected token
        ' shows up as the library failing to load.
        if reg.Read("servers") <> "" then
            m.prompt.text = "Connecting to " + NxKindName(kind) + "…"
            startLibrary(true)
            m.mbCheck = CreateObject("roSGNode", "MediaBrowserSignInTask")
            m.mbCheck.action = "check"
            m.mbCheck.ObserveField("status", "onMbCheck")
            m.mbCheck.control = "run"
        else
            showConnect()
        end if
        return
    end if
    if NxPlexLoadToken() = "" then
        showConnect()
        return
    end if
    if reg.Read("servers") <> "" and reg.Read("needsPick") = "" then startLibrary(true)
    startSignIn()
end sub

' The saved Jellyfin or Emby sign-in was refused: back to CONNECT YOUR
' LIBRARY, with the reason.
sub onMbCheck()
    if m.mbCheck = invalid or m.mbCheck.status <> "rejected" then return
    message = m.mbCheck.message
    signOut()
    m.connect.notice = message
end sub

' CONNECT YOUR SERVER (ConnectView): Plex, Jellyfin or Emby, for a TV that
' isn't signed in. A login dialog for the launch beacons. Plex's plex.tv/link
' code shows there too (plexState, plexCode), as on the Apple TV.
sub showConnect()
    if m.connect <> invalid then return
    m.prompt.text = ""
    m.hint.text = ""
    m.connect = CreateObject("roSGNode", "ConnectView")
    m.connect.ObserveField("done", "onConnectDone")
    m.connect.ObserveField("plexCancel", "onPlexCancel")
    m.top.AppendChild(m.connect)
    m.connect.SetFocus(true)
    signInShown()
end sub

sub closeConnect()
    if m.connect = invalid then return
    m.top.RemoveChild(m.connect)
    m.connect = invalid
    m.top.SetFocus(true)
end sub

sub onConnectDone()
    done = m.connect.done
    if done = "plex" then
        ' The code shows on the connect screen; it closes once signed in.
        m.connect.plexCode = ""
        m.connect.plexState = "connecting"
        startSignIn()
        return
    end if
    closeConnect()
    ' Signed in to Jellyfin or Emby: the first run's clock starts here, as it
    ' does once a Plex code is entered.
    signInDone()
    m.signedInClock = CreateObject("roTimespan")
    m.prompt.text = "Connecting to " + NxKindName(done) + "…"
    m.hint.text = ""
    startLibrary(true)
end sub

' CANCEL on the Plex code: the connect screen is back on its first choices,
' and the sign-in waiting on plex.tv stops.
sub onPlexCancel()
    if m.signIn <> invalid then
        m.signIn.UnobserveField("status")
        m.signIn.UnobserveField("code")
        m.signIn.control = "stop"
        m.signIn = invalid
    end if
    if m.connect <> invalid then m.connect.plexState = ""
end sub

sub startSignIn()
    m.prompt.text = "Connecting to Plex…"
    m.hint.text = ""
    m.signIn = CreateObject("roSGNode", "PlexSignInTask")
    m.signIn.ObserveField("status", "onSignInState")
    ' Every 5 minutes the task fetches a fresh code while status stays "code",
    ' so the code is watched on its own.
    m.signIn.ObserveField("code", "onSignInCode")
    m.signIn.control = "run"
end sub

sub onSignInState()
    state = m.signIn.status
    if state = "checking" then
        m.prompt.text = "Checking your Plex sign-in…"
        m.hint.text = ""
    else if state = "code" then
        ' The saved sign-in was rejected: nothing saved stays on screen.
        dropGuide()
        m.codeShown = true
        m.prompt.text = ""
        m.hint.text = ""
        showConnect()
        m.connect.plexCode = m.signIn.code
        m.connect.plexState = "code"
        signInShown()
    else if state = "discovering" then
        if m.connect <> invalid then m.connect.plexState = "finding"
        m.prompt.text = "Signed in as " + m.signIn.account + ". Finding your Plex servers…"
        m.hint.text = ""
        ' The first run's clock, after a code was entered on a phone (a first
        ' launch or a sign-out): the maintainer's bar is the guide up within
        ' 2 minutes of signing in.
        if m.codeShown = true then
            m.codeShown = false
            m.signedInClock = CreateObject("roTimespan")
        end if
        signInDone()
    else if state = "ready" then
        closeConnect()
        m.prompt.text = m.signIn.message
        m.hint.text = signOutHint()
        if NxPlexRegistry().Read("needsPick") <> "" then
            showPicker()
        else if m.library = invalid then
            startLibrary(true)
        end if
    else if state = "error" and m.connect <> invalid then
        ' From the Plex code: back to the first choices with the reason in
        ' red, as upstream; CONNECT TO PLEX tries again.
        message = m.signIn.message
        onPlexCancel()
        m.connect.notice = message
    else if state = "error" then
        ' A saved guide stays up through a network blip.
        m.prompt.text = m.signIn.message
        m.hint.text = signOutHint()
        launchComplete()
    end if
end sub

sub showPicker()
    if m.picker <> invalid then return
    servers = ParseJson(NxPlexRegistry().Read("servers"))
    if type(servers) <> "roArray" then servers = []
    list = []
    for each s in servers
        list.Push({ name: NxToStr(s.name), machineIdentifier: NxToStr(s.machineIdentifier), owned: NxTruthy(s.owned) })
    end for
    m.pickerClock = CreateObject("roTimespan")
    m.picker = CreateObject("roSGNode", "ServerPickerView")
    m.picker.ObserveField("choices", "onPicked")
    m.top.AppendChild(m.picker)
    m.picker.servers = list
    launchComplete()
end sub

' The choices are saved as Settings saves them, and only the servers picked
' are then checked and read.
sub onPicked()
    reg = NxPlexRegistry()
    reg.Write("serverChoices", FormatJson(m.picker.choices))
    reg.Delete("needsPick")
    reg.Flush()
    closePicker()
    print "library: libraries picked after "; m.pickerClock.TotalMilliseconds(); " ms at the picker; the sign-in clock starts again here"
    if m.signedInClock <> invalid then m.signedInClock = CreateObject("roTimespan")
    m.prompt.text = "Connecting to your servers…"
    startLibrary(true)
end sub

sub closePicker()
    if m.picker = invalid then return
    m.top.RemoveChild(m.picker)
    m.picker = invalid
    m.top.SetFocus(true)
end sub

sub onSignInCode()
    if m.signIn.status = "code" and m.connect <> invalid then m.connect.plexCode = m.signIn.code
end sub

' Roku certification times each launch to the AppLaunchComplete beacon, sent
' once, when the guide or an error that OK retries is first on screen. A
' plex.tv/link sign-in before that is a login dialog: AppDialogInitiate when
' its code shows, AppDialogComplete when sign-in finishes, so the time spent
' at a phone isn't counted as launch time.
sub signInShown()
    if m.launched = true or m.inSignIn = true then return
    m.inSignIn = true
    m.top.signalBeacon("AppDialogInitiate")
end sub

sub signInDone()
    if m.inSignIn <> true then return
    m.inSignIn = false
    m.top.signalBeacon("AppDialogComplete")
end sub

sub launchComplete()
    if m.launched = true then return
    signInDone()
    m.launched = true
    m.top.signalBeacon("AppLaunchComplete")
end sub

sub startLibrary(useCache = false as Boolean, rebuild = false as Boolean, rescan = false as Boolean)
    releaseLibrary()
    m.library = CreateObject("roSGNode", "LibraryTask")
    m.library.ObserveField("bundleBuilt", "onBundleBuilt")
    m.library.useCache = useCache
    m.library.rebuild = rebuild
    m.library.rescan = rescan
    m.library.ObserveField("refreshed", "onLibraryRefreshed")
    setLibraryBusy(true)
    m.library.ObserveField("phase", "onLibraryPhase")
    m.library.ObserveField("status", "onLibraryStatus")
    m.library.ObserveField("scanning", "onScanning")
    m.library.control = "run"
end sub

' The stall watch over a server's scan (source/util/LoadStall.brs), as
' upstream's withLibraryLoadStallWatch: every 2 s while it runs, the scan's
' progress fields and answers count, compared with the last look. Quiet
' for 60 s, the loading screen offers STOP WAITING; for 210 s, the scan is
' stopped. A background refresh, under the guide, says nothing and is only
' stopped.
sub onScanning()
    if m.library = invalid then return
    if not m.library.scanning then
        stopStallWatch()
        return
    end if
    if m.stallTimer = invalid then
        m.stallTimer = CreateObject("roSGNode", "Timer")
        m.stallTimer.duration = 2
        m.stallTimer.repeat = true
        m.stallTimer.ObserveField("fire", "onStallTick")
    end if
    m.stallClock = CreateObject("roTimespan")
    m.stall = NxStallStart(stallSample(), 0)
    m.stallTimer.control = "start"
end sub

function stallSample() as String
    t = m.library
    return t.phase + "|" + t.progress + "|" + t.bar.ToStr() + "|" + t.barCaption + "|" + t.scanAnswers.ToStr()
end function

sub onStallTick()
    if m.library = invalid or not m.library.scanning or m.stall = invalid then
        stopStallWatch()
        return
    end if
    verdict = NxStallVerdict(m.stall, stallSample(), m.stallClock.TotalMilliseconds())
    if m.loading <> invalid then m.loading.stalling = verdict <> "progressing"
    if verdict = "stalled" then
        print "library: no scan progress for "; NxStallStopAfterMs() \ 1000; " s, abandoning this scan"
        stopWaiting("stall")
    end if
end sub

' Ends the scan running, with what it has read (LibraryTask.stopWaiting).
sub stopWaiting(reason as String)
    if m.library = invalid or not m.library.scanning then return
    if m.library.stopWaiting <> "" then return
    m.library.stopWaiting = reason
    stopStallWatch()
end sub

sub stopStallWatch()
    if m.stallTimer <> invalid then m.stallTimer.control = "stop"
    m.stall = invalid
    if m.loading <> invalid then m.loading.stalling = false
end sub

' The progress screen (LoadingView) goes up once the load is under way and
' there is no guide to show; the saved guide, when there is one, comes first.
sub onLibraryPhase()
    if m.library = invalid then return
    if m.guide <> invalid or m.loading <> invalid or m.library.phase = "" then return
    m.loading = CreateObject("roSGNode", "LoadingView")
    m.loading.scanHeadline = NxScanHeadline(NxSignedInKind())
    m.top.AppendChild(m.loading)
    m.loading.task = m.library
end sub

sub closeLoading()
    if m.loading = invalid then return
    m.top.RemoveChild(m.loading)
    m.loading = invalid
end sub

sub onLibraryStatus()
    if m.library = invalid then return
    status = m.library.status
    if status = "error" then
        setLibraryBusy(false)
        if m.guide <> invalid then return
        closeLoading()
        m.signedInClock = invalid
        m.prompt.text = m.library.message
        m.hint.text = "Press OK to try again, or * to sign out of " + NxKindName(NxSignedInKind()) + " on this TV."
        launchComplete()
    else if status = "ready" then
        closeLoading()
        m.prompt.text = ""
        m.hint.text = ""
        m.top.FindNode("title").visible = false
        first = m.guide = invalid
        if first and m.signedInClock <> invalid then
            print "library: guide on screen "; m.signedInClock.TotalMilliseconds(); " ms after sign-in"
            m.signedInClock = invalid
        end if
        if first then
            m.guide = CreateObject("roSGNode", "GuideView")
            m.guide.ObserveField("action", "onGuideAction")
            m.guide.ObserveField("bundleRequest", "onBundleRequest")
            m.guide.ObserveField("rescanRequest", "onRescanRequest")
            m.guide.libraryBusy = m.libraryBusy
            if m.pendingLink <> invalid then m.guide.deepLink = m.pendingLink
            m.pendingLink = invalid
            if m.resumeId <> invalid then m.guide.resumeId = m.resumeId
            m.resumeId = invalid
            m.top.AppendChild(m.guide)
        end if
        m.guide.guide = m.library.guide
        if first then m.guide.SetFocus(true)
        launchComplete()
        if m.scheduleTimer = invalid then
            m.scheduleTimer = CreateObject("roSGNode", "Timer")
            m.scheduleTimer.duration = 30
            m.scheduleTimer.repeat = true
            m.scheduleTimer.ObserveField("fire", "onScheduleTimer")
            m.scheduleTimer.control = "start"
        end if
    end if
end sub

' A deep link goes to the guide, or waits for it while sign-in or the
' library load runs.
sub onDeepLink()
    if m.guide <> invalid then
        m.guide.deepLink = m.top.deepLink
    else
        m.pendingLink = m.top.deepLink
    end if
end sub

' A package switched in Settings: the running library task builds for it
' behind Settings and says when (LibraryTask.bundleRequest).
sub onBundleRequest()
    ' A task that has ended (a refresh that failed outright) would never answer.
    if m.library = invalid or m.library.state <> "run" then
        print "library: package change needs a full rebuild: no library task running"
        m.guide.bundleBuilt = "rebuild"
        return
    end if
    m.library.bundleRequest = true
end sub

sub onBundleBuilt()
    if m.guide <> invalid and m.library <> invalid then m.guide.bundleBuilt = m.library.bundleBuilt
end sub

sub onScheduleTimer()
    if m.library <> invalid then m.library.reschedule = true
end sub

' Stops the library task and stops listening to it: a task told to stop can
' still report once more, and its handlers read m.library.
sub releaseLibrary()
    if m.library = invalid then return
    m.library.UnobserveField("bundleBuilt")
    m.library.UnobserveField("phase")
    m.library.UnobserveField("status")
    m.library.UnobserveField("scanning")
    m.library.UnobserveField("refreshed")
    stopStallWatch()
    m.library.control = "stop"
    m.library = invalid
    m.libraryBusy = false
end sub

sub dropGuide()
    releaseLibrary()
    closeLoading()
    if m.guide <> invalid then
        m.top.RemoveChild(m.guide)
        m.guide = invalid
    end if
    m.top.FindNode("title").visible = true
    m.top.SetFocus(true)
end sub

' RESCAN LIBRARY (upstream's rescanLibrary): every server read again behind
' the guide, as the launch refresh is, and the guide swaps only if the pools
' changed. Not while a load is still running, as upstream's row does nothing
' while it says Updating.
sub onRescanRequest()
    if m.libraryBusy = true or m.guide = invalid then return
    print "library: rescan asked for in Settings"
    startLibrary(true, false, true)
end sub

sub onLibraryRefreshed()
    setLibraryBusy(false)
    startMusicLookup()
end sub

' The music-video genre lookups behind the guide (#73), as upstream's
' startDeferredMusicEnrichmentIfNeeded: after the guide is up, only with
' HIGH ROTATION on, one pass at a time. What they find is in the cache the
' next library load reads (the 6-hour refresh, RESCAN LIBRARY or a launch),
' as on the Apple TV, whose pass changes no channel's pool either.
sub startMusicLookup()
    if m.musicTask <> invalid or m.library = invalid then return
    items = NxList(m.library.musicVideos)
    if items.Count() = 0 then return
    m.musicTask = CreateObject("roSGNode", "MusicLookupTask")
    m.musicTask.items = items
    m.musicTask.ObserveField("written", "onMusicLookupDone")
    m.musicTask.control = "run"
end sub

sub onMusicLookupDone()
    m.musicTask = invalid
end sub

sub stopMusicLookup()
    if m.musicTask = invalid then return
    m.musicTask.UnobserveField("written")
    m.musicTask.control = "stop"
    m.musicTask = invalid
end sub

' Whether a library load is running, for the RESCAN LIBRARY row.
sub setLibraryBusy(busy as Boolean)
    m.libraryBusy = busy
    if m.guide <> invalid then m.guide.libraryBusy = busy
end sub

sub onGuideAction()
    action = m.guide.action
    ' The rebuilt guide opens on the same channel, not the top row.
    m.resumeId = m.guide.callFunc("tunedChannelId", invalid)
    dropGuide()
    if action = "signOut" then
        m.resumeId = ""
        signOut()
    else if action = "rebuild" then
        m.prompt.text = "Rebuilding your channels…"
        startLibrary(true, true)
    end if
end sub

sub signOut()
    if m.signIn <> invalid then m.signIn.control = "stop"
    stopMusicLookup()
    ' A launch check still running is for the sign-in going away: its late
    ' "rejected" must not sign out the next one.
    if m.mbCheck <> invalid then
        m.mbCheck.UnobserveField("status")
        m.mbCheck.control = "stop"
        m.mbCheck = invalid
    end if
    closePicker()
    dropGuide()
    closeConnect()
    NxPlexClearAuth()
    ' The saved library and the caches made from it go with the sign-in.
    NxClearAccountCaches()
    m.prompt.text = ""
    m.hint.text = ""
    showConnect()
end sub

function signOutHint() as String
    return "Press * to sign out of " + NxKindName(NxSignedInKind()) + " on this TV."
end function

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    ' Sign out from the sign-in and error screens only: stop any sign-in in
    ' progress and forget everything stored. With the guide up, * is the
    ' guide's own, and sign-out is in Settings, behind a second OK.
    if key = "options" and m.guide = invalid then
        signOut()
        return true
    end if
    if key = "OK" and m.signIn <> invalid and m.signIn.status = "error" then
        startSignIn()
        return true
    end if
    ' STOP WAITING, on a loading screen whose scan has gone quiet.
    if key = "OK" and m.loading <> invalid and m.loading.stalling then
        print "library: the viewer stopped waiting on the library scan"
        stopWaiting("viewer")
        return true
    end if
    if key = "OK" and m.library <> invalid and m.library.status = "error" then
        startLibrary(true)
        return true
    end if
    return false
end function
