' Runs source/guide/SleepTimer.brs against upstream's SleepTimerLogic
' (Services/NowPlayingPanelLogic.swift): presets 15, 30, 60, a running
' timer kept among them, and its labels. And source/guide/NowPlayingLayout.brs
' against NowPlayingPanelLayout.programRows from the same file. Transcribed
' from the Swift (NowPlayingPanelLogicTests), not generated. Returns the
' failure count.

function NxRunSleepTimerTests() as Integer
    r = { pass: 0, fail: 0 }

    NxCheck(r, "offered none", FormatJson(NxSleepOffered(0)), "[15,30,60]")
    NxCheck(r, "offered preset", FormatJson(NxSleepOffered(30)), "[15,30,60]")
    NxCheck(r, "offered 45 kept", FormatJson(NxSleepOffered(45)), "[15,30,45,60]")
    NxCheck(r, "offered 90 kept", FormatJson(NxSleepOffered(90)), "[15,30,60,90]")
    NxCheck(r, "offered 5 kept", FormatJson(NxSleepOffered(5)), "[5,15,30,60]")

    NxCheck(r, "label off", NxSleepLabel(0), "OFF")
    NxCheck(r, "label 30", NxSleepLabel(30), "30 MIN")
    NxCheck(r, "label 60", NxSleepLabel(60), "1 HR")
    NxCheck(r, "label 90", NxSleepLabel(90), "1 HR 30 MIN")
    NxCheck(r, "label 120", NxSleepLabel(120), "2 HR")

    NxCheck(r, "countdown 0", NxSleepCountdown(0), "0:00")
    NxCheck(r, "countdown 65", NxSleepCountdown(65), "1:05")
    NxCheck(r, "countdown 1799", NxSleepCountdown(1799), "29:59")
    NxCheck(r, "countdown 3600", NxSleepCountdown(3600), "1:00:00")
    NxCheck(r, "countdown 3725", NxSleepCountdown(3725), "1:02:05")
    NxCheck(r, "countdown negative", NxSleepCountdown(-4), "0:00")

    ' programRows (#118), OPEN IN PLEX left out on the Roku.
    NxCheck(r, "rows: no subtitles, one audio track", NxPanelProgramRows(false, 1).Join(","), "header,captions,audio")
    NxCheck(r, "rows: no subtitles, no audio keeps cc", NxPanelProgramRows(false, 0).Join(","), "header,captions,audio")
    NxCheck(r, "rows: subtitles add their preferences", NxPanelProgramRows(true, 1).Join(","), "header,captions,subtitleLanguage,autoSubtitles,audio")
    NxCheck(r, "rows: two audio tracks add audio language", NxPanelProgramRows(false, 2).Join(","), "header,captions,audio,audioLanguage")
    NxCheck(r, "rows: everything, in order", NxPanelProgramRows(true, 3).Join(","), "header,captions,subtitleLanguage,autoSubtitles,audio,audioLanguage")

    ' ── The Now Playing panel's UP NEXT badge (#266, Variant A) ──
    NxCheck(r, "up next: 84 minutes", NxUpNextBadge(84 * 60), "UP NEXT IN 84 MIN")
    NxCheck(r, "up next: minutes only, never hours", NxUpNextBadge(120 * 60), "UP NEXT IN 120 MIN")
    NxCheck(r, "up next: whole minutes rounded down", NxUpNextBadge(84 * 60 + 59), "UP NEXT IN 84 MIN")
    NxCheck(r, "up next: just over a minute is one", NxUpNextBadge(61), "UP NEXT IN 1 MIN")
    NxCheck(r, "up next: exactly a minute", NxUpNextBadge(60), "UP NEXT IN 1 MIN")
    NxCheck(r, "up next: under a minute", NxUpNextBadge(59), "UP NEXT IN LESS THAN 1 MIN")
    NxCheck(r, "up next: due now", NxUpNextBadge(0), "UP NEXT IN LESS THAN 1 MIN")
    NxCheck(r, "up next: already started", NxUpNextBadge(-30), "UP NEXT IN LESS THAN 1 MIN")
    NxCheck(r, "up next: no number", NxUpNextBadge(invalid), "UP NEXT IN LESS THAN 1 MIN")

    ' ── The panel's measures: the Apple TV 1.0.32's NowPlayingMetrics.swift (#266) ──
    pm = NxPanelMetrics()
    NxCheck(r, "metrics: text 22, title 29, tag 28", pm.text.ToStr() + "," + pm.title.ToStr() + "," + pm.tag.ToStr(), "22,29,28")
    NxCheck(r, "metrics: row 64, padding 18, gap 8", pm.rowH.ToStr() + "," + pm.padX.ToStr() + "," + pm.rowGap.ToStr(), "64,18,8")
    NxCheck(r, "metrics: columns 440, 28 apart", pm.colW.ToStr() + "," + pm.colGap.ToStr(), "440,28")
    NxCheck(r, "metrics: poster 120 by 180, 18 to the text", pm.posterW.ToStr() + "," + pm.posterH.ToStr() + "," + pm.posterGap.ToStr(), "120,180,18")
    NxCheck(r, "metrics: the two columns are 908 wide", (2 * pm.colW + pm.colGap).ToStr(), "908")

    ' ── The hint line under the controls (NowPlayingPanelHints) ──
    NxCheck(r, "audio row: no track is a plain row", NxToStr(NxAudioRowOpensList(0)), "false")
    NxCheck(r, "audio row: one track is a plain row", NxToStr(NxAudioRowOpensList(1)), "false")
    NxCheck(r, "audio row: a choice opens the list", NxToStr(NxAudioRowOpensList(2)), "true")
    NxCheck(r, "hint: audio", NxPanelHint("pick:audioTracks"), "Pick the audio track for this program.")
    NxCheck(r, "hint: cc", NxPanelHint("cc"), "Subtitles on or off for every program.")
    NxCheck(r, "hint: retro", NxPanelHint("retro"), "CRT scanlines, vignette, flicker, 4:3 aspect ratio.")
    NxCheck(r, "hint: stream quality", NxPanelHint("pick:streamQuality"), "Takes effect on the next program.")
    NxCheck(r, "hint: sleep timer", NxPanelHint("pick:sleep"), "Stops playback after the time you pick. A still-watching prompt comes first.")
    NxCheck(r, "hint: playback information", NxPanelHint("info"), "Source codecs and how this program reaches the screen: direct play, remux or transcode.")
    NxCheck(r, "hint: an option in a list has none", NxPanelHint("sleep:15"), "")
    NxCheck(r, "hint: no id has none", NxPanelHint(invalid), "")

    ' ── Up and Down in full screen (PlayerView): Down opens the Now Playing panel at the top, Up the
    ' channel strip at the bottom, and each is closed by the reverse of what opened it. ──
    NxCheck(r, "keys: bare Down opens the panel", NxOverlayKey("", "down", false, false), "panel")
    NxCheck(r, "keys: bare Up opens the strip", NxOverlayKey("", "up", false, false), "strip")
    NxCheck(r, "keys: bare Left is the previous channel", NxOverlayKey("", "left", false, false), "previous")
    NxCheck(r, "keys: bare Right is the next channel", NxOverlayKey("", "right", false, false), "next")
    NxCheck(r, "keys: bare OK is not an overlay key", NxOverlayKey("", "OK", false, false), "")
    NxCheck(r, "keys: Up on a column's first row closes the panel", NxOverlayKey("panel", "up", true, false), "close")
    NxCheck(r, "keys: Up on any other row moves", NxOverlayKey("panel", "up", false, false), "")
    NxCheck(r, "keys: Up inside a list never closes the panel", NxOverlayKey("panel", "up", true, true), "")
    NxCheck(r, "keys: Down in the panel moves", NxOverlayKey("panel", "down", true, false), "")
    NxCheck(r, "keys: Down closes the strip", NxOverlayKey("strip", "down", false, false), "close")
    NxCheck(r, "keys: Up in the strip does nothing", NxOverlayKey("strip", "up", false, false), "")
    NxCheck(r, "keys: Left and Right keep moving along the strip", NxOverlayKey("strip", "left", false, false) + NxOverlayKey("strip", "right", false, false), "")

    print "sleep timer cases (upstream SleepTimerLogic, NowPlayingPanelLayout): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function
