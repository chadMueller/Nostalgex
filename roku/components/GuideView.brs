' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Layout, type and colour follow the Nostalgex Apple TV app's guide (see
' GuideView.xml). The grid follows its ChannelGuideView: a two-hour window
' from the current half hour, 425 px per 30 minutes, scrolled a slot at a
' time with left/right, up to 22 hours ahead, the focused row kept in the
' middle. Rounded outlines, glows, the CRT overlay and snow are images from
' scripts/look-images.py. Unlike the Apple TV, the grid isn't shifted right
' by its header's overflow (about 30 px there): the rows line up with the
' header here.

sub init()
    m.colX = 220
    m.slotWidth = 425
    m.rowPitch = 81
    ' The grid's rows below its header: 525 - 61.
    m.viewHeight = 464
    m.windowSec = 7200
    m.focus = 0
    m.scrollY = 0
    ' Where focus is: "grid", the seasonal "invite" row, or the "settings" nav item.
    m.nav = "grid"
    m.offer = invalid
    m.tracked = {}
    m.trackedWidth = {}
    m.advance = {}
    m.tuned = -1
    m.sawPlaying = false
    m.unplayedEnds = 0
    m.tuneQueue = NxTuneQueue()
    ' The fallback ladder (source/guide/Fallback.brs): the running start's
    ' attempt, the one to start next, programmes failed in a row, and
    ' whether the channel has stopped trying.
    m.attempt = invalid
    m.pendingAttempt = invalid
    m.failRun = NxFailureRun()
    ' PLAYBACK INFORMATION (source/guide/PlaybackInfo.brs): the programme's
    ' record, its generation and the running attempt's id.
    m.pi = invalid
    m.piGen = 0
    m.piAttempt = invalid
    m.stopped = false
    m.slotOffset = 0
    m.playing = invalid
    m.fullscreen = false
    m.fonts = {}
    ' Packages switched on in Settings whose build hasn't answered: { id: true }.
    m.building = {}

    styleLabel("graceTitle", "DMMono-Medium", 34, "0xFFFFFFFF")
    styleLabel("graceCount", "DMMono-Regular", 23, "0xFFFFFFD9")
    styleLabel("graceHint", "DMMono-Regular", 19, "0xFFFFFFA6")
    styleLabel("navSettings", "DMMono-Medium", 24, "0xFFFFFF80")
    styleLabel("buildNotice", "DMMono-Medium", 22, "0xFFE500FF")
    styleLabel("title", "DMMono-Medium", 38, "0xFFFFFFFF")
    styleLabel("artist", "DMMono-Regular", 22, "0xFFFFFFB3")
    styleLabel("genres", "DMMono-Regular", 22, "0xFFFFFFBF")
    styleLabel("subtitle", "DMMono-Regular", 22, "0xFFFFFFB3")
    styleLabel("summary", "DMMono-Regular", 20, "0xFFFFFFA6")
    styleLabel("clock", "VT323-Regular", 24, "0xFFFFFF8C")
    styleLabel("upNext", "DMMono-Regular", 18, "0xFFFFFFBF")
    applyGuideText()
    styleLabel("hazeText", "DMMono-Medium", 26, "0xFFFFFF6B")
    styleLabel("notice", "DMMono-Regular", 20, "0xFF6B6BFF")
    styleLabel("ccToast", "VT323-Regular", 48, "0xFFFFFFFF")
    m.deadlineTimer = newTimer(15, false, "onDeadline")
    m.cardTimer = newTimer(5, false, "onCardDone")
    ' The playhead, once a second, for NxStarvationObserve.
    m.starveTimer = newTimer(1, true, "onStarveTick")
    m.starveClock = CreateObject("roTimespan")
    ' SHOW NOW PLAYING and MARK WATCHED (source/guide/PlaybackReport.brs):
    ' the airing's tracker, the 10-second pulse and the clock it runs on.
    m.reportScope = NxReportScope(NxReportPrefs())
    m.tracker = invalid
    m.reportSent = 0
    m.reportTimer = newTimer(10, true, "onReportTick")
    m.reportClock = CreateObject("roTimespan")

    m.video = m.top.FindNode("video")
    m.video.ObserveField("state", "onVideoState")
    m.video.ObserveField("bufferingStatus", "onBuffering")
    m.video.ObserveField("availableSubtitleTracks", "applySubtitles")
    ' Now Playing follows the player: a track switch, and the track lists
    ' that arrive after a start (subtitles through applySubtitles).
    m.video.ObserveField("currentAudioTrack", "refreshNowPlaying")
    m.video.ObserveField("availableAudioTracks", "onAudioTracks")
    m.subs = NxSubtitleSettings()
    m.hasSubs = false
    restoreCaptionMode()
    m.tick = CreateObject("roSGNode", "Timer")
    m.tick.repeat = true
    m.tick.duration = 1
    m.tick.ObserveField("fire", "onTick")
    m.lastWindow = 0
    reg = NxRegSection("player")
    m.stopUrl = reg.Read("stopUrl")
    m.stopServer = reg.Read("stopServer").ToInt()

    ' RETRO MODE's moving parts, as CRTOverlayView's: a flicker check every
    ' 0.08 s, and a tracking glitch that may roll through every 6-15 s.
    m.flicker = newTimer(0.08, true, "onFlicker")
    m.flickerBack = newTimer(0.06, false, "onFlickerBack")
    m.glitchTimer = newTimer(10, false, "onGlitchTimer")
    m.top.FindNode("glitchAnim").ObserveField("state", "onGlitchDone")
    ' The tuning snow's frames, changed every 0.07 s as StaticScreenView's.
    m.snowTimer = newTimer(0.07, true, "onSnowTimer")
    m.snowFrame = 0
    m.retro = NxRetroMode()
    layoutVideo()
end sub

function newTimer(duration as Float, rpt as Boolean, handler as String) as Object
    t = CreateObject("roSGNode", "Timer")
    t.duration = duration
    t.repeat = rpt
    t.ObserveField("fire", handler)
    return t
end function

function fontOf(name as String, size as Integer) as Object
    key = name + size.ToStr()
    if m.fonts[key] = invalid then
        f = CreateObject("roSGNode", "Font")
        f.uri = "pkg:/fonts/" + name + ".ttf"
        f.size = size
        m.fonts[key] = f
    end if
    return m.fonts[key]
end function

sub styleLabel(id as String, font as String, size as Integer, color as String)
    lbl = m.top.FindNode(id)
    lbl.font = fontOf(font, size)
    lbl.color = color
end sub

' GUIDE TEXT SIZE (source/guide/GuideText.brs): the grid's sizes for the saved
' choice, and the CHANNEL heading set to match. True when the sizes changed,
' so the grid wants drawing again.
function applyGuideText() as Boolean
    large = NxGuideTextLarge()
    ' Never compare invalid to a Boolean: the first call has no choice yet.
    if m.guideText <> invalid then
        if m.guideTextLarge = large then return false
    end if
    m.guideTextLarge = large
    m.guideText = NxGuideTextSizes(large)
    styleLabel("channelHead", "DMMono-Medium", m.guideText.head, "0xFFFFFFB3")
    m.top.FindNode("channelHead").translation = [12, m.guideText.headY]
    return true
end function

function newLabel(text as String, font as String, size as Integer, color as String, x as Float, y as Float, width as Float) as Object
    lbl = CreateObject("roSGNode", "Label")
    lbl.text = text
    lbl.font = fontOf(font, size)
    lbl.color = color
    lbl.translation = [x, y]
    if width > 0 then
        lbl.width = width
        ' One glyph, as SwiftUI truncates, not "...": on the tuned row, whose
        ' bolt chip narrows the name as on the Apple TV, the three dots took
        ' two more letters (Discussion #8). DM Mono has U+2026.
        lbl.ellipsisText = Chr(8230)
    end if
    return lbl
end function

function newRect(x as Float, y as Float, w as Float, h as Float, color as String) as Object
    r = CreateObject("roSGNode", "Rectangle")
    r.translation = [x, y]
    r.width = w
    r.height = h
    r.color = color
    return r
end function

sub onGuide()
    previous = m.channels
    m.channels = m.top.guide.channels
    m.gaveWay = invalid
    ' No channel at all (libraries that build none): the time header and
    ' ChannelGuideView's NO CHANNELS AVAILABLE, and Up still reaches SETTINGS.
    ' Nothing reads a channel while the list is empty (#93).
    if m.channels = invalid then m.channels = []
    if m.channels.Count() = 0 then
        ' Upstream's NO CHANNELS FOUND, with OK for its OPEN SETTINGS (#60).
        m.top.FindNode("notice").text = "NO CHANNELS FOUND" + Chr(10) + "Your library didn't have enough content to fill any channels. Open Settings to see which packages your library supports." + Chr(10) + Chr(10) + "OK  OPEN SETTINGS"
        keepFocusVisible()
        renderGrid()
        return
    end if
    refreshOffer()
    refreshSettings()
    ' An empty guide that now has channels starts as a first one: the clock
    ' never ran for it.
    if previous = invalid or previous.Count() = 0 then
        if previous = invalid then m.top.SetFocus(true)
        m.tick.control = "start"
        ' Back from SETTINGS on the empty guide left focus on m.tuned, -1.
        m.focus = 0
        ' A launch deep link opens on its channel, fullscreen; an item link
        ' plays its item once it's found, and nothing starts before it.
        linked = NxDeepLinkChannel(m.channels, m.top.deepLink)
        itemId = NxDeepLinkItem(m.top.deepLink, CreateObject("roAppInfo").IsDev())
        ' After a full rebuild from Settings, the channel that was on.
        resumed = -1
        if linked < 0 and m.top.resumeId <> "" then
            for i = 0 to m.channels.Count() - 1
                if NxToStr(m.channels[i].id) = m.top.resumeId then resumed = i
            end for
        end if
        if linked >= 0 then
            m.focus = linked
            keepFocusVisible()
        else if resumed >= 0 then
            m.focus = resumed
            keepFocusVisible()
        end if
        renderGrid()
        if itemId <> "" then
            findLinkedItem(itemId)
        else if linked >= 0 then
            pressTune(linked)
            setFullscreen(true)
        else if resumed >= 0 then
            pressTune(resumed)
        else
            pressTune(0)
        end if
        return
    end if

    ' A refreshed guide (the library changed under the saved one): keep the
    ' tuned channel and focus by id, and retune only if what airs now changed.
    tunedId = invalid
    if m.tuned >= 0 and m.tuned < previous.Count() then tunedId = previous[m.tuned].id
    focusId = invalid
    if m.focus < previous.Count() then focusId = previous[m.focus].id
    m.tuned = 0
    m.focus = 0
    for i = 0 to m.channels.Count() - 1
        if m.channels[i].id = tunedId then m.tuned = i
        if m.channels[i].id = focusId then m.focus = i
    end for
    NxTuneMoved(m.tuneQueue, m.tuned)
    ' The mini strip and the sidebar hold channel indexes: with another
    ' channel list, a pick would land on whatever took that place. An hourly
    ' reschedule keeps the list, so they stay open then.
    moved = previous.Count() <> m.channels.Count()
    for i = 0 to m.channels.Count() - 1
        if moved then exit for
        if previous[i].id <> m.channels[i].id then moved = true
    end for
    if moved then
        closeStrip()
        if m.sidebarOpen = true then closeSidebar()
    end if
    keepFocusVisible()
    renderGrid()
    renderInfo()
    now = blockAt(m.channels[m.tuned], nowSec())
    same = now <> invalid and m.playing <> invalid
    if same then same = now.ratingKey = m.playing.ratingKey and now.startSec = m.playing.startSec
    ' An airing still running past its slot finishes first.
    if not same and m.playing <> invalid then
        t = nowSec()
        if t >= m.playing.endSec and not NxAiringEnded(m.playing, t, m.video.state) then same = true
        ' So does a deep-linked item, which no channel airs.
        if m.playing.linked = true then same = true
    end if
    ' An item link being looked up starts its own.
    if not same and not m.stopped and m.itemTask = invalid then tune(m.tuned)
end sub

function tunedChannelId(unused = invalid as Dynamic) as String
    if m.channels = invalid or m.tuned < 0 or m.tuned >= m.channels.Count() then return ""
    return NxToStr(m.channels[m.tuned].id)
end function

' ── Clock ───────────────────────────────────────────────────────────────────

function nowSec() as LongInteger
    dt = CreateObject("roDateTime")
    s& = dt.AsSeconds()
    return s&
end function

function localTimeLabel(epochSec as LongInteger) as String
    dt = CreateObject("roDateTime")
    dt.FromSeconds(epochSec)
    dt.ToLocalTime()
    h = dt.GetHours()
    ampm = "AM"
    if h >= 12 then ampm = "PM"
    h12 = h mod 12
    if h12 = 0 then h12 = 12
    mm = dt.GetMinutes()
    mmStr = mm.ToStr()
    if mm < 10 then mmStr = "0" + mmStr
    return h12.ToStr() + ":" + mmStr + " " + ampm
end function

' h:mm:ss, or m:ss under an hour.
function hms(sec as LongInteger) as String
    if sec < 0 then sec = 0
    h = sec \ 3600
    mm = (sec mod 3600) \ 60
    ss = sec mod 60
    out = ""
    if h > 0 then out = h.ToStr() + ":"
    if mm < 10 and h > 0 then out = out + "0"
    out = out + mm.ToStr() + ":"
    if ss < 10 then out = out + "0"
    return out + ss.ToStr()
end function

' ── Schedule lookups ────────────────────────────────────────────────────────

' What is on at t: the schedule's now (NxBlockOnAir), what tuning in plays.
function blockAt(ch as Object, t as LongInteger) as Dynamic
    return NxBlockOnAir(ch.blocks, t)
end function

function blockAfter(ch as Object, b as Object) as Dynamic
    for each x in ch.blocks
        if x.startSec >= b.endSec then return x
    end for
    return invalid
end function

function colorOf(hex as String, alpha as String) as String
    h = hex.Replace("#", "")
    if h.Len() <> 6 then h = "FFFFFF"
    return "0x" + UCase(h) + alpha
end function

' ── Grid ────────────────────────────────────────────────────────────────────

function windowStart() as LongInteger
    t = nowSec()
    return (t \ 1800) * 1800 + m.slotOffset * 1800
end function

' Rows above channel one: the seasonal invite while a package is on offer.
function leadRows() as Integer
    if m.offer <> invalid then return 1
    return 0
end function

sub renderGrid()
    t = nowSec()
    wStart& = windowStart()
    wEnd& = wStart& + m.windowSec
    m.lastWindow = (t \ 1800) * 1800
    scale = (m.slotWidth * 4) / m.windowSec

    slots = m.top.FindNode("slots")
    slots.RemoveChildrenIndex(slots.GetChildCount(), 0)
    for i = 0 to 3
        x = m.colX + i * m.slotWidth
        ' Only as tall as the time text: ChannelGuideView draws them as its overlay.
        slots.AppendChild(newRect(x, m.guideText.slotY, 1, m.guideText.slotH, "0xFFFFFF33"))
        slots.AppendChild(newLabel(localTimeLabel(wStart& + i * 1800), "DMMono-Medium", m.guideText.slot, "0xFFFFFFF2", x + 14, m.guideText.slotY, 0))
    end for

    ' Only the rows in or touching the viewport, which clips them.
    rows = m.top.FindNode("rows")
    rows.RemoveChildrenIndex(rows.GetChildCount(), 0)
    lead = leadRows()
    ' One title on two channels: the lowest channel id keeps it (NxGaveWay),
    ' once per second however often the grid redraws.
    if m.gaveWay = invalid or m.gaveWayAt <> t then
        m.gaveWay = NxGaveWay(m.channels, t)
        m.gaveWayAt = t
    end if
    for idx = 0 to m.channels.Count() - 1
        y = m.scrollY + (idx + lead) * m.rowPitch
        if y > -m.rowPitch and y < m.viewHeight then rows.AppendChild(renderRow(idx, y, t, wStart&, wEnd&, scale))
    end for
    ' The focused row's outline and glow go over its neighbours; so does the
    ' invite, as its zIndex puts it.
    if m.nav = "grid" and m.focus >= 0 and m.focus < m.channels.Count() then
        y = m.scrollY + (m.focus + lead) * m.rowPitch
        rows.AppendChild(newOutline("focus", y, colorOf(m.channels[m.focus].color, "FF")))
    end if
    if lead > 0 and m.scrollY > -m.rowPitch then rows.AppendChild(renderInvite(m.scrollY))

    line = m.top.FindNode("nowLine")
    ' Floats throughout: LongInteger / Integer divides as integers (giving 0
    ' here), and node fields reject a Double.
    elapsed! = t - wStart&
    frac! = elapsed! / m.windowSec
    line.visible = frac! >= 0 and frac! <= 1
    x! = m.colX + frac! * m.slotWidth * 4
    line.translation = [x!, 0]
end sub

' A row's rounded outline with its glow (scripts/look-images.py), tinted:
' 16 px of glow either side of the 1920 x 80 row.
function newOutline(name as String, y as Integer, color as String) as Object
    p = CreateObject("roSGNode", "Poster")
    p.uri = "pkg:/images/look/" + name + ".9.png"
    p.translation = [-16, y - 16]
    p.width = 1952
    p.height = 112
    p.blendColor = color
    return p
end function

function renderRow(idx as Integer, y as Integer, t as LongInteger, wStart& as LongInteger, wEnd& as LongInteger, scale as Float) as Object
    ch = m.channels[idx]
    focused = m.nav = "grid" and idx = m.focus
    tuned = idx = m.tuned
    gave = m.gaveWay[idx.ToStr()]
    color = colorOf(ch.color, "FF")
    row = CreateObject("roSGNode", "Group")
    row.translation = [0, y]

    stripe = invalid
    if focused then
        stripe = colorOf(ch.color, "52")
    else if idx mod 2 = 0 then
        stripe = "0xFFFFFF08"
    end if
    if stripe <> invalid then row.AppendChild(newRect(0, 0, 1920, 80, stripe))
    row.AppendChild(newRect(0, 80, 1920, 1, "0xFFFFFF14"))

    ' Programs, with the now-airing cell in the channel's colour.
    nowB = blockAt(ch, t)
    for each b in ch.blocks
        if b.endSec > wStart& and b.startSec < wEnd& then
            s& = b.startSec
            if s& < wStart& then s& = wStart&
            e& = b.endSec
            if e& > wEnd& then e& = wEnd&
            x = m.colX + 1 + (s& - wStart&) * scale
            w = (e& - s&) * scale
            onNow = false
            if nowB <> invalid then onNow = b.startSec = nowB.startSec and b.ratingKey = nowB.ratingKey
            ' A channel giving the title way to a lower one doesn't mark it as on
            ' now, as the web tuner's guide (rebuildAllSchedules); it still plays it
            ' when tuned, as the Apple TV does.
            if onNow and gave <> invalid then
                if gave.gaveWay.startSec = b.startSec and gave.gaveWay.ratingKey = b.ratingKey then onNow = false
            end if
            past = b.endSec <= t
            if onNow then
                fill = colorOf(ch.color, "40")
                if focused then fill = colorOf(ch.color, "8C")
                row.AppendChild(newRect(x, 0, w, 80, fill))
            else if past then
                row.AppendChild(newRect(x, 0, w, 80, "0xFFFFFF05"))
            end if
            row.AppendChild(newRect(x, 0, 1, 80, "0xFFFFFF1F"))
            ' The title runs to the block's edge, 15 in from its start.
            if w > 15 then
                tc = "0xFFFFFFD9"
                if onNow or focused then
                    tc = "0xFFFFFFFF"
                else if past then
                    tc = "0xFFFFFF80"
                end if
                row.AppendChild(newLabel(b.line, "DMMono-Medium", m.guideText.title, tc, x + 15, m.guideText.titleY, w - 15))
            end if
        end if
    end for

    ' Channel column, drawn over the programs' left edge; the row's stripe or
    ' focus fill runs through it, as on the Apple TV.
    row.AppendChild(newRect(0, 0, m.colX, 80, "0x0D0D1FFF"))
    if stripe <> invalid then row.AppendChild(newRect(0, 0, m.colX, 80, stripe))
    accentW = 4
    if focused or tuned then
        accentW = 8
        row.AppendChild(newRect(0, 0, 8, 80, color))
    else
        row.AppendChild(newRect(0, 0, 4, 80, colorOf(ch.color, "66")))
    end if
    row.AppendChild(newRect(m.colX, 0, 1, 80, "0xFFFFFF26"))
    numColor = color
    nameColor = colorOf(ch.color, "F2")
    if focused then
        numColor = "0xFFFFFFFF"
        nameColor = "0xFFFFFFFF"
    end if
    x = accentW + 6
    if tuned then
        ' The live chip: a bolt on the channel's colour, then 6 to the number.
        x = accentW + 8
        row.AppendChild(newRect(x, 28, 17, 23, color))
        bolt = CreateObject("roSGNode", "Poster")
        bolt.uri = "pkg:/images/look/bolt.png"
        bolt.translation = [x + 4, 33]
        bolt.width = 9
        bolt.height = 13
        row.AppendChild(bolt)
        x = x + 17 + 6
    end if
    gt = m.guideText
    num = newLabel(ch.number.ToStr(), "DMMono-Medium", gt.num, numColor, x, gt.numY, gt.numW)
    num.horizAlign = "right"
    row.AppendChild(num)
    row.AppendChild(newLabel(UCase(ch.name), "DMMono-Medium", gt.name, nameColor, x + gt.nameGap, gt.nameY, m.colX - x - gt.nameGap))
    return row
end function

' The seasonal invite (SeasonalInviteRow): one row tall, in the season's
' colour, with its one call to action in a capsule.
function renderInvite(y as Integer) as Object
    accent = NxSeasonalAccent(m.offer)
    focused = m.nav = "invite"
    row = CreateObject("roSGNode", "Group")
    row.translation = [0, y]
    fill = colorOf(accent, "38")
    if focused then fill = colorOf(accent, "FF")
    row.AppendChild(newRect(0, 0, 1920, 80, fill))
    if focused then
        row.AppendChild(newOutline("seasonal_focus", 0, colorOf(accent, "FF")))
        row.AppendChild(newRect(0, 0, 8, 80, colorOf(accent, "FF")))
    else
        row.AppendChild(newOutline("seasonal", 0, colorOf(accent, "FF")))
        row.AppendChild(newRect(0, 0, 4, 80, colorOf(accent, "FF")))
    end if
    hc = colorOf(accent, "FF")
    if focused then hc = "0x000000FF"
    head = newLabel(NxSeasonalHeadline(m.offer, NxSeasonNow()), "DMMono-Medium", 22, hc, 20, 25, 0)
    row.AppendChild(head)
    px = 20 + head.boundingRect().width + 14
    cta = newLabel("PRESS TO ADD THE " + UCase(NxToStr(m.offer.name)) + " PACKAGE", "DMMono-Medium", 14, "0x000000FF", px + 11, 31, 0)
    if focused then cta.color = "0x000000A6"
    pill = CreateObject("roSGNode", "Poster")
    pill.uri = "pkg:/images/look/capsule.9.png"
    pill.translation = [px, 26]
    pill.width = cta.boundingRect().width + 22
    pill.height = 28
    pill.blendColor = colorOf(accent, "FF")
    if focused then pill.blendColor = "0x0000002E"
    row.AppendChild(pill)
    row.AppendChild(cta)
    return row
end function

' Text spaced like SwiftUI's .tracking(n): one Label per character, at the
' font's advance plus n (both fonts are monospace). Rebuilt only when the
' text or colour changes. Returns the width.
function setTracked(id as String, text as String, font as String, size as Integer, color as String, tracking as Integer) as Float
    g = m.top.FindNode(id)
    key = text + "|" + color
    if m.tracked[id] = key then return m.trackedWidth[id]
    g.RemoveChildrenIndex(g.GetChildCount(), 0)
    adv = advanceOf(font, size) + tracking
    for i = 0 to Len(text) - 1
        g.AppendChild(newLabel(Mid(text, i + 1, 1), font, size, color, i * adv, 0, 0))
    end for
    w = Len(text) * adv - tracking
    m.tracked[id] = key
    m.trackedWidth[id] = w
    return w
end function

function advanceOf(font as String, size as Integer) as Float
    key = font + size.ToStr()
    if m.advance[key] = invalid then
        probe = newLabel("0000000000", font, size, "0xFFFFFFFF", 0, 0, 0)
        m.advance[key] = probe.boundingRect().width / 10
    end if
    return m.advance[key]
end function

' ── Info panel: follows focus; for the tuned channel, what is playing ───────

sub renderInfo()
    if m.channels = invalid or m.channels.Count() = 0 then return
    ch = m.channels[m.focus]
    t = nowSec()
    b = blockAt(ch, t)
    if m.focus = m.tuned and m.playing <> invalid then b = m.playing
    color = colorOf(ch.color, "FF")
    num = ch.number.ToStr()
    if ch.number < 10 then num = "0" + num
    setTracked("tag", "CH " + num + " — " + UCase(ch.name), "VT323-Regular", 36, color, 2)
    m.top.FindNode("rule").color = colorOf(ch.color, "4D")
    m.top.FindNode("progressFill").color = color

    title = m.top.FindNode("title")
    names = ["artist", "genres", "subtitle", "rule", "summary", "meta", "upNextLabel", "upNext"]
    if b = invalid then
        ' The tag alone, as InfoPanelView shows with nothing scheduled.
        title.text = ""
        for each n in names
            m.top.FindNode(n).visible = false
        end for
        return
    end if
    for each n in names
        m.top.FindNode(n).visible = true
    end for
    title.text = b.title

    ' The stack, 10 apart (Spacing.innerGap): title, artist and genres for a
    ' music video, the episode line, then the rule.
    y = 56 + title.boundingRect().height + 10
    artist = m.top.FindNode("artist")
    artist.visible = NxTruthy(b.music) and NxToStr(b.artist) <> ""
    if artist.visible then
        artist.text = b.artist
        artist.translation = [0, y]
        y = y + artist.boundingRect().height + 10
    end if
    genres = m.top.FindNode("genres")
    genres.visible = NxTruthy(b.music) and NxToStr(b.genreLine) <> ""
    if genres.visible then
        genres.text = b.genreLine
        genres.color = colorOf(ch.color, "BF")
        genres.translation = [0, y]
        y = y + genres.boundingRect().height + 10
    end if
    subtitle = m.top.FindNode("subtitle")
    subLine = episodeLine(b)
    subtitle.visible = subLine <> ""
    if subtitle.visible then
        subtitle.text = subLine
        subtitle.translation = [0, y]
        y = y + subtitle.boundingRect().height + 10
    end if
    m.top.FindNode("rule").translation = [0, y]
    y = y + 1 + 20
    summary = m.top.FindNode("summary")
    summary.text = b.summary
    summary.translation = [0, y]
    if b.summary <> "" then y = y + summary.boundingRect().height + 20

    ' Meta row: year and content rating badges, the star rating, then the
    ' progress bar, which takes what the time leaves.
    meta = m.top.FindNode("meta")
    meta.translation = [0, y]
    badges = m.top.FindNode("badges")
    key = b.year + "|" + NxToStr(b.contentRating) + "|" + NxToStr(b.rating)
    if m.badgesKey <> key then
        m.badgesKey = key
        badges.RemoveChildrenIndex(badges.GetChildCount(), 0)
        x = 0
        for each text in [b.year, NxToStr(b.contentRating)]
            if text <> "" then
                lbl = newLabel(text, "VT323-Regular", 24, "0xFFFFFFB3", x + 12, 5, 0)
                w = lbl.boundingRect().width + 24
                frame = CreateObject("roSGNode", "Poster")
                frame.uri = "pkg:/images/look/badge.9.png"
                frame.translation = [x, 0]
                frame.width = w
                frame.height = 34
                frame.opacity = 0.15
                badges.AppendChild(frame)
                badges.AppendChild(lbl)
                x = x + w + 14
            end if
        end for
        if NxIsNumber(b.rating) and b.rating > 0 then
            ' None of the fonts has a star, so it's an image (look-images.py).
            star = CreateObject("roSGNode", "Poster")
            star.uri = "pkg:/images/look/star.png"
            star.translation = [x, 8]
            star.width = 16
            star.height = 16
            star.blendColor = "0xFFE500FF"
            badges.AppendChild(star)
            x = x + 16 + 6
            r10 = Int(b.rating * 10 + 0.5)
            score = newLabel((r10 \ 10).ToStr() + "." + (r10 mod 10).ToStr(), "VT323-Regular", 24, "0xFFFFFF99", x, 5, 0)
            badges.AppendChild(score)
            x = x + score.boundingRect().width + 14
        end if
        m.badgesWidth = x
    end if
    x = m.badgesWidth
    clock = m.top.FindNode("clock")
    dur& = b.endSec - b.startSec
    pos& = t - b.startSec
    clock.text = hms(pos&) + " / " + hms(dur&)
    cw = clock.boundingRect().width
    clock.translation = [1100 - cw, 5]
    track = m.top.FindNode("progressTrack")
    barW = 1100 - cw - 10 - x
    if barW < 0 then barW = 0
    track.translation = [x, 15]
    track.width = barW
    fill = m.top.FindNode("progressFill")
    fill.translation = [x, 15]
    ' Past the slot while the file finishes, the bar stays full.
    if pos& > dur& then
        fill.width = barW
    else if dur& > 0 then
        fill.width = barW * pos& / dur&
    else
        fill.width = 0
    end if

    y = y + 34 + 20
    n = blockAfter(ch, b)
    m.top.FindNode("upNextLabel").visible = n <> invalid
    up = m.top.FindNode("upNext")
    up.visible = n <> invalid
    if n <> invalid then
        lw = setTracked("upNextLabel", "UP NEXT", "VT323-Regular", 24, "0xFFFFFF80", 3)
        m.top.FindNode("upNextLabel").translation = [0, y]
        up.translation = [lw + 10, y]
        up.text = musicLine(n)
    end if
end sub

' The episode line: S01E04, then two spaces and the episode's title.
function episodeLine(b as Object) as String
    if b.type <> "episode" then return ""
    parts = []
    se = seTag(b)
    if se <> "" then parts.Push(se)
    if NxTruthy(b.episodeTitle) then parts.Push(b.episodeTitle)
    return parts.Join("  ")
end function

function seTag(b as Object) as String
    if not NxIsNumber(b.seasonNumber) or not NxIsNumber(b.episodeNumber) then return ""
    return "S" + pad2(b.seasonNumber) + "E" + pad2(b.episodeNumber)
end function

function pad2(n as Dynamic) as String
    s = NxToStr(n)
    if s.Len() < 2 then s = "0" + s
    return s
end function

' musicDisplayLine: "Artist · Title" for a music video, else the title.
function musicLine(b as Object) as String
    if NxTruthy(b.music) and NxToStr(b.artist) <> "" then return b.artist + " · " + b.title
    return NxToStr(b.title)
end function

sub onTick()
    checkSleep()
    if m.np <> invalid and (m.sleepEnd <> invalid or m.np.infoOpen = true) then m.np.state = npState()
    renderInfo()
    if m.fullscreen then updateOsdTime()
    t = nowSec()
    if (t \ 1800) * 1800 <> m.lastWindow or t mod 30 = 0 then renderGrid()
    ' Live: when the airing's slot is over and its file isn't still playing,
    ' the channel moves on to what is on now, where the clock is, unless
    ' another channel has that title on (source/guide/Advance.brs).
    ' A channel that stopped trying stays stopped until the viewer tunes.
    ' A deep-linked item ends with its file, however long it stalled.
    linked = m.playing <> invalid and m.playing.linked = true
    if NxAiringEnded(m.playing, t, m.video.state) and not m.stopped and not linked then advance(false)
    warmSubtitles(t)
end sub

' Every 5 minutes, the subtitle files of airings on now or within the hour,
' forced ones and with SUBTITLES on ALWAYS full ones, asked of their
' Jellyfin or Emby server ahead of time, each once (NxSubtitleWarmList),
' one batch at a time. The list of files asked starts
' again past 500, so a guide left up for weeks can't grow it without end; a
' file then may be asked once more, from the server's own copy.
sub warmSubtitles(t as LongInteger)
    if m.warmTask <> invalid then return
    if m.warmAt <> invalid and t - m.warmAt < 300 then return
    m.warmAt = t
    if m.warmDone = invalid or m.warmDone.Count() > 500 then m.warmDone = {}
    servers = {}
    saved = ParseJson(NxPlexRegistry().Read("servers"))
    if type(saved) = "roArray" then
        for i = 0 to saved.Count() - 1
            base = NxToStr(saved[i].uri)
            lower = LCase(base)
            ' As NxMbStreamContent: HTTPS, or plain HTTP to a home address.
            ok = Left(lower, 8) = "https://" or (Left(lower, 7) = "http://" and NxIsPrivateHost(NxUrlHost(base)))
            if NxServerKind(saved[i]) <> "plex" and ok then servers[i.ToStr()] = base
        end for
    end if
    if servers.Count() = 0 then return
    urls = NxSubtitleWarmList(m.channels, t, 3600, NxSubPreferredLanguage(), m.subs.always, NxMbViewerLanguages(), servers, m.warmDone, NxSqCurrent())
    if urls.Count() = 0 then return
    for each u in urls
        m.warmDone[u] = true
    end for
    m.warmTask = CreateObject("roSGNode", "SubtitleWarmTask")
    m.warmTask.ObserveField("done", "onWarmDone")
    m.warmTask.urls = urls
    m.warmTask.control = "run"
end sub

sub onWarmDone()
    m.warmTask = invalid
end sub

' ── Playback ────────────────────────────────────────────────────────────────

' Plex refuses a second transcode for the same device while one runs (HTTP
' 400), so the running one is stopped first and the channel starts when the
' stop has gone through. Only the latest press starts (source/guide/TuneQueue.brs).
sub tune(idx as Integer, nextAiring = invalid as Dynamic)
    ' From the press to the picture, stop included: the maintainer's bar is
    ' under 10 s for a converted channel, mid-programme too.
    ' A step down the fallback ladder keeps the clock running.
    if m.retrying <> true then
        m.tuneClock = CreateObject("roTimespan")
        ' Anything tuned meanwhile replaces a retry still waiting to fire,
        ' which would otherwise restart whatever is on by then.
        stopRetry()
        m.pendingAttempt = invalid
    end if
    m.retrying = false
    m.deadlineTimer.control = "stop"
    m.probing = false
    m.probeFor = invalid
    m.probeTask = invalid
    hideCard()
    action = NxTuneAsk(m.tuneQueue, idx, m.stopUrl <> invalid and m.stopUrl <> "")
    if action = "start" then
        m.nextAiring = nextAiring
        startTune(idx)
        return
    end if
    ' While it waits, the screen already shows the channel asked for, so the
    ' OSD and the next Up or Down go from it, not from the one stopping.
    m.tuned = idx
    ' A press for any channel drops a hand-over still waiting on the stop.
    m.nextAiring = nextAiring
    m.playing = nextAiring
    if m.playing = invalid then m.playing = blockAt(m.channels[idx], nowSec())
    renderInfo()
    renderGrid()
    if action = "stop" then stopPrevious()
end sub

' A tune the viewer asked for: the count of failures starts again, and a
' channel that stopped trying tries again (ChannelFailureRun.reset in
' AppState.selectChannel).
sub pressTune(idx as Integer)
    NxFailureReset(m.failRun)
    m.stopped = false
    tune(idx)
end sub

sub startTune(idx as Integer)
    m.tuned = idx
    ' Set when this start reaches "playing"; see onVideoState's "finished".
    ' A start that isn't a hand-over counts unplayed ends afresh; the one
    ' retry still bounds a loop through it.
    m.sawPlaying = false
    if m.nextAiring = invalid then m.unplayedEnds = 0
    ch = m.channels[idx]
    t = nowSec()
    ' A hand-over starts the next airing from its beginning; a press joins
    ' what airs now part way in.
    b = m.nextAiring
    m.nextAiring = invalid
    offset& = 0
    rung = "auto"
    ' A step down the ladder restarts the same airing where it was.
    pending = m.pendingAttempt
    m.pendingAttempt = invalid
    if pending <> invalid then
        b = pending.b
        offset& = pending.offset
        rung = pending.attempt.rung
    else if b = invalid then
        b = blockAt(ch, t)
        if b <> invalid then offset& = t - b.startSec
    end if
    m.top.FindNode("notice").text = ""
    armHaze()
    renderInfo()
    renderGrid()
    if b = invalid then
        stopTracker()
        m.playing = invalid
        m.video.control = "stop"
        return
    end if
    stream = NxStreamContent(b, offset&, rung)
    m.playing = b
    trackAiring(b, offset&)
    ' A new programme gets its own record; a step down the ladder is a new
    ' attempt on the same one.
    if pending = invalid then
        m.piGen = m.piGen + 1
        kind = NxServerKind(NxStreamServer(b))
        m.pi = NxPiCreate({ generation: m.piGen, backend: kind, qualityAtTune: NxPiQualityLabel(NxSqCurrent()), videoCodec: b.videoCodec, audioCodec: b.audioCodec })
        m.piAttempt = invalid
    end if
    if stream = invalid then
        m.attempt = invalid
        giveUp("nostream")
        return
    end if
    if pending <> invalid then m.attempt = pending.attempt else m.attempt = NxFirstAttempt(stream.rung)
    if pending <> invalid and pending.piStep <> invalid then
        m.piAttempt = NxPiBeginAttempt(m.pi, m.piGen, NxPiDeliveryFor(m.attempt.rung), pending.piStep.reason, pending.piStep.recovery)
    else
        m.piAttempt = NxPiBeginAttempt(m.pi, m.piGen, NxPiDeliveryFor(m.attempt.rung), NxPiFirstReason(m.attempt.rung))
    end if
    m.tuneOffset = offset&
    ' For NxProbeStream only; never printed (it can carry a session).
    m.streamUrl = stream.content.url
    m.stopUrl = stream.stopUrl
    m.stopServer = b.serverIndex
    rememberStop()
    NxApplyStreamAuth(m.video, b)
    m.video.content = stream.content
    m.video.control = "play"
    m.tuneFormat = stream.content.streamFormat
    ' The Jellyfin/Emby pick on a direct play; on every other stream, AUDIO
    ' LANGUAGE among the tracks the player lists (issue #62).
    m.tuneAudio = stream.audioTrack
    m.tuneForced = stream.forcedSub = true
    if m.tuneAudio = invalid then m.tuneAudio = { language: NxAudioPreferredLanguage(), byLanguage: true }
    m.deadlineTimer.duration = NxPictureDeadline(m.attempt.rung, b.videoWidth, b.videoHeight)
    m.deadlineTimer.control = "start"
    ' Each start watched afresh, so an old stream's stalls never count here.
    m.starve = NxStarvation()
    m.starveTimer.control = "start"
    print "player: tuned channel "; ch.id; ", "; stream.content.streamFormat; " stream over "; stream.route; ", "; offset&; " s into the airing ("; m.attempt.rung; ", "; m.deadlineTimer.duration; " s for a picture)"
    refreshNowPlaying()
end sub

' ── SHOW NOW PLAYING and MARK WATCHED ─────────────────────────────────────

function reportingOn() as Boolean
    return m.reportScope.nowPlaying = true or m.reportScope.markWatched = true
end function

function reportNow() as Double
    return m.reportClock.TotalMilliseconds() / 1000.0
end function

' A new airing gets a tracker; a retry or a step down of the same airing
' keeps its own, as upstream's onPlaybackReady is idempotent.
sub trackAiring(b as Object, offset& as LongInteger)
    if NxReportSameAiring(m.tracker, b) then return
    stopTracker()
    s = NxStreamServer(b)
    if s = invalid then return
    session = LCase(CreateObject("roDeviceInfo").GetRandomUUID().Replace("-", ""))
    m.tracker = NxReportTracker(b, offset&, NxServerKind(s), session)
    base = NxToStr(s.uri)
    if NxTruthy(s.lanUri) then base = NxToStr(s.lanUri)
    ' Carried with each event, so a stop still goes out after a sign-out.
    m.tracker.server = { kind: NxServerKind(s), base: base, token: NxToStr(s.accessToken), userId: NxToStr(s.userId) }
end sub

sub stopTracker()
    m.reportTimer.control = "stop"
    if m.tracker = invalid then return
    sendReports(NxReportStop(m.tracker, m.reportScope, reportNow()))
    m.tracker = invalid
end sub

sub reportPlayerState(state as String)
    if m.tracker = invalid then return
    if state = "playing" and not m.tracker.ready then
        sendReports(NxReportReady(m.tracker, m.reportScope, reportNow()))
        m.reportTimer.control = "start"
        return
    end if
    if state = "playing" or state = "paused" or state = "buffering" then sendReports(NxReportPlayerState(m.tracker, m.reportScope, state))
end sub

sub onReportTick()
    if m.tracker = invalid then
        m.reportTimer.control = "stop"
        return
    end if
    sendReports(NxReportTick(m.tracker, m.reportScope, reportNow()))
end sub

' Settings closed: the choices as saved. A change applies to what plays now
' without retuning; the task drops queued work a choice turned off at once.
sub applyReportPrefs()
    was = { nowPlaying: m.reportScope.nowPlaying, markWatched: m.reportScope.markWatched }
    NxReportScopeUpdate(m.reportScope, NxReportPrefs())
    task = reportTask(false)
    if task <> invalid then task.scope = m.reportScope
    if m.tracker <> invalid then sendReports(NxReportUpdate(m.tracker, was, m.reportScope))
end sub

' The report task, kept on the scene so a stop still goes out after the
' guide is gone; made the first time there is something to send.
function reportTask(make as Boolean) as Dynamic
    scene = m.top.getScene()
    task = scene.FindNode("reportTask")
    if task = invalid and make then
        task = CreateObject("roSGNode", "ReportTask")
        task.id = "reportTask"
        scene.AppendChild(task)
        task.control = "run"
    end if
    return task
end function

sub sendReports(events as Object)
    if events.Count() = 0 then return
    ' With both choices off since launch nothing was ever reported: no task,
    ' no request.
    if not reportingOn() and reportTask(false) = invalid then return
    task = reportTask(true)
    task.scope = m.reportScope
    for each ev in events
        ev.server = m.tracker.server
        task.event = ev
        m.reportSent = m.reportSent + 1
    end for
end sub

' Leaving: once every event sent has run, or after 4 s, the app closes.
sub leaveAfterReports()
    task = reportTask(false)
    if task = invalid or task.processed >= m.reportSent then
        m.top.getScene().leave = true
        return
    end if
    print "guide: waiting for the server to hear playback stopped"
    task.ObserveField("processed", "onReportsRun")
    m.leaveTimer = newTimer(4, false, "onLeaveTimer")
    m.leaveTimer.control = "start"
end sub

sub onReportsRun()
    task = reportTask(false)
    if task <> invalid and task.processed < m.reportSent then return
    if task <> invalid then task.UnobserveField("processed")
    m.top.getScene().leave = true
end sub

sub onLeaveTimer()
    print "guide: the server didn't answer in 4 s; closing the app"
    m.top.getScene().leave = true
end sub

sub onBuffering()
    st = m.video.bufferingStatus
    if st <> invalid then print "player: buffering "; st.percentage; "%"
end sub

' A stream that played and now can't be fed (PlaybackStarvation): one rung
' down from where it got to, and "couldn't keep up" once the 1080p stream
' starves too (handleStarvation). Only after a picture: the start is the
' deadline's, and a stop or a probe owns the player meanwhile.
sub onStarveTick()
    if m.attempt = invalid or m.playing = invalid or m.probing = true or m.sawPlaying <> true then return
    state = m.video.state
    if state <> "playing" and state <> "buffering" and state <> "paused" then return
    position = m.video.position
    if not NxIsNumber(position) then return
    remaining = invalid
    duration = m.video.duration
    if NxIsNumber(duration) and duration > 0 then remaining = duration - position
    v = NxStarvationObserve(m.starve, position, m.starveClock.TotalMilliseconds() / 1000#, state = "paused", remaining)
    if v = invalid then return
    m.starveTimer.control = "stop"
    print "player: starved on the "; m.attempt.rung; " stream: "; v.stalls; " stall(s), longest "; Int(v.longest); " s, at "; Int(position); " s"
    nxt = NxStarvedNext(m.attempt)
    if nxt = invalid then
        giveUp("starved")
        return
    end if
    stepDown(nxt, "starved")
end sub

' Release the transcode the last airing started, so the NAS stops working
' on a channel nobody is watching.
sub stopPrevious()
    if m.stopUrl = invalid or m.stopUrl = "" then return
    m.video.control = "stop"
    m.stopTask = CreateObject("roSGNode", "PlexStopTask")
    m.stopTask.stopUrl = m.stopUrl
    m.stopTask.serverIndex = m.stopServer
    m.stopTask.ObserveField("state", "onStopDone")
    m.stopTask.control = "run"
    m.stopUrl = ""
    rememberStop()
end sub

sub onStopDone()
    if m.stopTask.state <> "stop" then return
    if m.leaving = true then
        print "guide: the stop answered; closing the app"
        leaveAfterReports()
        return
    end if
    idx = NxTuneStopped(m.tuneQueue)
    if idx >= 0 then startTune(idx)
end sub

' The running transcode's stop address (no token in it), kept across
' launches: a transcode left running by the last launch blocks this one's.
sub rememberStop()
    reg = NxRegSection("player")
    if m.stopUrl = invalid or m.stopUrl = "" then
        reg.Delete("stopUrl")
    else
        reg.Write("stopUrl", m.stopUrl)
        reg.Write("stopServer", m.stopServer.ToStr())
    end if
    reg.Flush()
end sub

sub onVideoState()
    state = m.video.state
    print "player: "; state
    reportPlayerState(state)
    if state = "playing" then
        if m.tuneClock <> invalid then
            print "player: picture after "; m.tuneClock.TotalMilliseconds(); " ms ("; m.tuneFormat; ")"
            m.tuneClock = invalid
        end if
        m.deadlineTimer.control = "stop"
        NxFailureReset(m.failRun)
        if m.pi <> invalid then NxPiMarkReady(m.pi, m.piGen, m.piAttempt)
        m.sawPlaying = true
        m.unplayedEnds = 0
        hideHaze()
        ' The track list may not change between two files with the same
        ' tracks, and then onAudioTracks never runs for this start.
        applyAudioPick()
        applySubtitles()
    end if
    ' What "finished" means (NxFinishedAction). A start the server refused
    ' can end this way never having played: handing over then bounced
    ' between the airing on now and the next one, three requests a second
    ' for four minutes against an Emby answering 401. One such end hands
    ' over (joined past where a file shorter than its slot ends, the next
    ' airing is right); a second in a row is a failed start. And one that
    ' comes after the start already failed is the player's, not the file's.
    if state = "finished" then
        rung = ""
        if m.attempt <> invalid then rung = m.attempt.rung
        fin = NxFinishedAction({ attemptRunning: m.attempt <> invalid, sawPlaying: m.sawPlaying, unplayedEnds: m.unplayedEnds, rung: rung, probing: m.probing })
        m.unplayedEnds = fin.unplayedEnds
        if fin.action = "ignore" then
            print "player: finished after the start failed; its retry or card goes on"
            return
        else if fin.action = "error" then
            print "player: finished without playing again; treating it as an error"
            state = "error"
        else if fin.action = "probe" then
            ' A server stream the server couldn't make ends this way too
            ' (a file gone from disk: Emby's playlist failed and the player
            ' reported "finished"). Asked first, so a join past the end of
            ' a short file still hands over.
            print "player: the server stream finished without playing; asking the server"
            startProbe("error", invalid, true)
            return
        else
            ' The file ended: hand over to the next airing, as upstream does
            ' on AVPlayerItemDidPlayToEndTime.
            handOver()
            return
        end if
    end if
    if state = "error" then
        print "player: error "; m.video.errorCode; " "; m.video.errorMsg
        e = m.video.errorInfo
        if e <> invalid then print "player: error category "; e.category; " code "; e.errcode; " source "; e.source
        failAttempt("error")
    end if
end sub

sub handOver()
    if m.tuned < 0 or m.playing = invalid then return
    ' A deep-linked item: the channel goes on live, part way into what airs.
    if m.playing.linked = true then
        tune(m.tuned)
        return
    end if
    print "player: finished, "; nowSec() - m.playing.endSec; " s past the slot"
    advance(true)
end sub

' What plays after the programme playing (NxAdvancePick, the Apple TV's
' advanceToNextItem): natural, the file played to its end, so the next one
' starts from its beginning; otherwise (a stall, a failure, a slot the file
' never finished) one already airing joins where the clock is. Nothing in the
' window: whatever is on now.
sub advance(natural as Boolean)
    if m.tuned < 0 or m.playing = invalid then return
    p = NxAdvancePick(m.channels, m.tuned, m.playing.ratingKey, nowSec(), natural)
    if p = invalid or p.seek > 0 then
        tune(m.tuned)
        return
    end if
    print "player: next is "; p.block.ratingKey; ", from its start"
    tune(m.tuned, p.block)
end sub

' No picture by the start's deadline (PlaybackWatchdog): Roku's player
' would otherwise wait on its own for as long as it likes.
sub onDeadline()
    if m.video.state = "playing" then return
    print "player: no picture after "; m.deadlineTimer.duration; " s ("; m.video.state; ")"
    failAttempt("nopicture")
end sub

' The running start failed: the next rung of the ladder, or the card. The
' server is asked first when the player said nothing (no picture) and before
' the card, as upstream asks it before its card and before the server
' stream (resolveServerStream); an error steps down at once, so a refusal
' that lasts a moment still gets its retry.
sub failAttempt(event as String)
    m.deadlineTimer.control = "stop"
    if m.attempt = invalid or m.playing = invalid or m.tuned < 0 or m.probing = true then return
    nxt = NxFallbackNext(m.attempt, event, NxServerKind(NxStreamServer(m.playing)))
    if event = "nopicture" or nxt = invalid then
        startProbe(event, nxt, false)
        return
    end if
    stepDown(nxt, event)
end sub

' finished: the stream ended unplayed, and an answer from the server means
' it was a join past the end of the file (handOver), not a failure.
sub startProbe(event as String, nxt as Dynamic, finished as Boolean)
    m.deadlineTimer.control = "stop"
    m.probing = true
    m.probeFor = { event: event, nxt: nxt, finished: finished }
    m.probeTask = CreateObject("roSGNode", "StreamProbeTask")
    m.probeTask.url = m.streamUrl
    m.probeTask.serverIndex = m.playing.serverIndex
    m.probeTask.ObserveField("code", "onProbeDone")
    m.probeTask.control = "run"
end sub

' The server's answer: a refusal, or nothing answering, ends the ladder with
' that as the reason; otherwise the next rung, or the card.
sub onProbeDone(ev as Object)
    ' Tuned away while it asked: a newer start owns the player.
    if m.probeTask = invalid or not ev.GetRoSGNode().IsSameNode(m.probeTask) then return
    m.probing = false
    code = ev.GetData()
    m.probeTask = invalid
    p = m.probeFor
    m.probeFor = invalid
    if p = invalid then return
    verdict = NxProbeVerdict(code)
    print "player: the server "; verdict; " ("; code; ")"
    if p.finished and verdict = "answered" then
        handOver()
        return
    end if
    if p.nxt = invalid or verdict <> "answered" then
        giveUp(p.event, code)
        return
    end if
    stepDown(p.nxt, p.event)
end sub

sub stepDown(nxt as Object, event as String)
    m.starveTimer.control = "stop"
    ' The same airing at the same point: where it got to, if it played.
    offset& = m.tuneOffset
    played = m.video.position
    if NxIsNumber(played) and played > offset& then offset& = Int(played)
    was = m.attempt.rung
    m.pendingAttempt = { b: m.playing, offset: offset&, attempt: nxt, piStep: NxPiStepReason(was, event, nxt) }
    m.attempt = invalid
    ' The player being replaced doesn't describe the next one.
    if m.pi <> invalid then NxPiInvalidate(m.pi)
    if nxt.retry then
        ' Plex can refuse a stream for a moment while the last one is still
        ' winding down, so the retry waits.
        print "player: "; event; " on the server stream; retrying it"
        m.retryTimer = newTimer(3, false, "onRetry")
        m.retryTimer.control = "start"
        return
    end if
    print "player: "; event; " on the "; was; " stream; trying the "; nxt.rung; " stream"
    m.retrying = true
    tune(m.tuned)
end sub

sub onRetry()
    m.retryTimer = invalid
    print "player: retrying"
    m.retrying = true
    tune(m.tuned)
end sub

' Nothing left to try: the card names why, the server's work stops, and
' after five seconds the next programme starts. The fifth in a row on a
' channel stops it instead, card and all, until the viewer tunes.
sub giveUp(event as String, probe = 1 as Integer)
    m.starveTimer.control = "stop"
    e = { server: "", event: event, rung: "", errorCode: 0, category: "", probe: probe, codec: invalid }
    if m.attempt <> invalid then e.rung = m.attempt.rung
    s = invalid
    if m.playing <> invalid then
        s = NxStreamServer(m.playing)
        e.codec = m.playing.videoCodec
    end if
    if s <> invalid then e.server = NxServerDisplayName(NxServerKind(s))
    if event = "error" then
        e.errorCode = m.video.errorCode
        info = m.video.errorInfo
        if info <> invalid then e.category = info.category
    end if
    card = NxPlaybackFailure(e)
    m.attempt = invalid
    m.video.control = "stop"
    ' A programme that won't play has ended, for the server too.
    stopTracker()
    stopPrevious()
    hideHaze()
    ends = NxFailureRecord(m.failRun, tunedChannelId())
    ' The verdict Settings' RESCAN LIBRARY row shows (PlaybackDiagnostics).
    title = ""
    if m.playing <> invalid then title = NxToStr(m.playing.title)
    NxRecordPlaybackVerdict(NxPlaybackVerdictLine(e, card, ends, title, nowSec()))
    print "player: gave up ("; card.kind; "), "; m.failRun.count; " in a row on this channel"
    if ends then
        m.stopped = true
        showCard(NxChannelStoppedCard(card))
        return
    end if
    showCard(card)
    m.cardTimer.control = "start"
end sub

' The card has had its five seconds: the next programme, from its start, or
' what airs now, where the clock is, if the schedule has moved past the one
' that failed (advanceToNextItem after a failure).
sub onCardDone()
    hideCard()
    if m.tuned < 0 or m.playing = invalid then return
    if m.playing.linked = true then
        tune(m.tuned)
        return
    end if
    advance(false)
end sub

sub showCard(card as Object)
    accent = "0xFFB020"
    if not card.serverSide then accent = "0xFF2244"
    m.card = card
    m.top.FindNode("failHead").text = card.headline
    m.top.FindNode("failHead").color = accent + "FF"
    m.top.FindNode("failDetail").text = card.detail
    m.top.FindNode("failNext").text = card.nextStep
    m.top.FindNode("failEdge").color = accent + "59"
    positionCard()
    m.top.FindNode("failCard").visible = true
end sub

sub hideCard()
    m.cardTimer.control = "stop"
    m.top.FindNode("failCard").visible = false
    m.card = invalid
end sub

' PlaybackFailureCard's sizes: compact over the guide's preview, larger full
' screen; centred on the video either way.
sub positionCard()
    if m.card = invalid then return
    if m.fullscreen then
        area = [0, 0, 1920, 1080]
        sizes = [38, 22, 17]
        textW = 900
        padX = 72
        padY = 48
        gap = 18
    else
        area = [1180, 0, 740, 555]
        sizes = [26, 16, 13]
        textW = 740 - 2 * (24 + 32)
        padX = 32
        padY = 28
        gap = 12
    end if
    head = m.top.FindNode("failHead")
    detail = m.top.FindNode("failDetail")
    nxt = m.top.FindNode("failNext")
    head.font = fontOf("DMMono-Medium", sizes[0])
    detail.font = fontOf("DMMono-Regular", sizes[1])
    detail.color = "0xFFFFFFBF"
    nxt.font = fontOf("DMMono-Regular", sizes[2])
    nxt.color = "0xFFFFFF66"
    for each lbl in [head, detail, nxt]
        lbl.width = textW
    end for
    hH = head.boundingRect().height
    dH = detail.boundingRect().height
    nH = nxt.boundingRect().height
    w = textW + 2 * padX
    h = hH + dH + nH + 2 * gap + 2 * padY
    x = area[0] + (area[2] - w) / 2
    y = area[1] + (area[3] - h) / 2
    edge = m.top.FindNode("failEdge")
    edge.translation = [x - 1, y - 1]
    edge.width = w + 2
    edge.height = h + 2
    bg = m.top.FindNode("failBg")
    bg.translation = [x, y]
    bg.width = w
    bg.height = h
    head.translation = [x + padX, y + padY]
    detail.translation = [x + padX, y + padY + hH + gap]
    nxt.translation = [x + padX, y + padY + hH + gap + dH + gap]
end sub

sub stopRetry()
    if m.retryTimer = invalid then return
    m.retryTimer.control = "stop"
    m.retryTimer.UnobserveField("fire")
    m.retryTimer = invalid
end sub

sub setFullscreen(on as Boolean)
    if not on then
        closeStrip()
        closeNowPlaying()
    end if
    m.fullscreen = on
    m.top.FindNode("panel").visible = not on
    m.top.FindNode("grid").visible = not on
    m.top.FindNode("videoBg").visible = not on
    layoutVideo()
    if on then
        showOsd()
    else
        onOsdTimer()
        m.top.FindNode("ccToast").visible = false
    end if
    positionHaze()
    positionCard()
    applySubtitles()
end sub

' ── RETRO MODE ──────────────────────────────────────────────────────────────

' Where the video and the CRT overlay go. In the guide, RETRO MODE crops the
' picture to the 4:3 box as the Apple TV app's .resizeAspectFill does: Roku's
' Video only letterboxes, so the video is sized 16:9 at the box's height,
' centred on it, and the panel (drawn after it) covers the left overflow; the
' right runs off the screen. A 4:3 file then fills the box exactly. Full
' screen keeps the whole picture, under the whole overlay, scanlines
' included since upstream e48cdc1 (RetroLook).
sub layoutVideo()
    crt = m.top.FindNode("crt")
    scan = m.top.FindNode("scanlines")
    vig = m.top.FindNode("vignette")
    gl = m.top.FindNode("glitch")
    if m.fullscreen then
        m.video.translation = [0, 0]
        m.video.width = 1920
        m.video.height = 1080
        crt.translation = [0, 0]
        crt.clippingRect = [0, 0, 1920, 1080]
        scan.uri = "pkg:/images/look/scanlines_full.png"
        scan.width = 1920
        scan.height = 1080
        vig.uri = "pkg:/images/look/vignette_full.png"
        vig.width = 1920
        vig.height = 1080
        gl.width = 1920
        m.crtHeight = 1080
    else
        if m.retro then
            m.video.translation = [1056.67, 0]
            m.video.width = 986.67
        else
            m.video.translation = [1180, 0]
            m.video.width = 740
        end if
        m.video.height = 555
        crt.translation = [1180, 0]
        crt.clippingRect = [0, 0, 740, 555]
        scan.uri = "pkg:/images/look/scanlines.png"
        scan.width = 740
        scan.height = 555
        vig.uri = "pkg:/images/look/vignette.png"
        vig.width = 740
        vig.height = 555
        gl.width = 740
        m.crtHeight = 555
    end if
    crt.visible = m.retro
    if m.retro then
        m.flicker.control = "start"
        if m.glitchTimer.control <> "start" then scheduleGlitch()
    else
        m.flicker.control = "stop"
        m.glitchTimer.control = "stop"
    end if
end sub

sub onFlicker()
    ' RetroLook: 8% of ticks, down to 0.76 to 0.88.
    if Rnd(0) > 1 - 0.08 then
        m.top.FindNode("scanlines").opacity = 0.76 + Rnd(0) * 0.12
        m.flickerBack.control = "start"
    end if
end sub

sub onFlickerBack()
    m.top.FindNode("scanlines").opacity = 1.0
end sub

sub scheduleGlitch()
    m.glitchTimer.duration = 6 + Rnd(0) * 9
    m.glitchTimer.control = "start"
end sub

sub onGlitchTimer()
    ' RetroLook: 45% of the checks.
    if Rnd(0) > 1 - 0.45 then
        ' A band 150-400 px long, starting within 200 px of the middle.
        y0! = m.crtHeight * 0.5 + (Rnd(0) * 400 - 200)
        travel! = 150 + Rnd(0) * 250
        m.top.FindNode("glitchMove").keyValue = [[0.0, y0!], [0.0, y0! + travel!]]
        anim = m.top.FindNode("glitchAnim")
        anim.duration = 0.5 + Rnd(0)
        m.top.FindNode("glitch").visible = true
        anim.control = "start"
    end if
    if m.retro then scheduleGlitch()
end sub

sub onGlitchDone()
    if m.top.FindNode("glitchAnim").state = "stopped" then m.top.FindNode("glitch").visible = false
end sub

' Settings may have switched RETRO MODE.
sub applyRetro()
    on = NxRetroMode()
    if on = m.retro then return
    m.retro = on
    layoutVideo()
end sub

sub onAudioTracks()
    applyAudioPick()
    refreshNowPlaying()
end sub

' A Jellyfin or Emby direct play selects the audio track the stream picked
' (NxMbAudioPick), once the player lists the file's tracks; their server
' stream already carries only that one. Any other stream takes the first
' track in AUDIO LANGUAGE, as upstream's applyAudioTrackSelection. Once per
' start, so a track the viewer chooses in Now Playing stays chosen. Only
' after the first picture: a switch while the start still buffered ended it
' as "finished" on a TCL 43S45, and stalled it 15 s on a Streaming Stick.
' Only a track the player isn't on is set.
sub applyAudioPick()
    if m.tuneAudio = invalid or m.sawPlaying <> true then return
    tracks = NxList(m.video.availableAudioTracks)
    if tracks.Count() = 0 then return
    if m.tuneAudio.byLanguage = true then
        track = NxAudioTrackForLanguage(tracks, m.tuneAudio.language)
    else
        track = NxAudioTrackToSelect(tracks, m.tuneAudio)
    end if
    listed = []
    for each a in tracks
        listed.Push(NxToStr(a.Track) + "=" + NxToStr(a.Language))
    end for
    print "player: audio track "; track; " of "; listed.Join(" "); ", was "; m.video.currentAudioTrack
    if track <> invalid and NxToStr(track) <> NxToStr(m.video.currentAudioTrack) then m.video.audioTrack = track
    m.tuneAudio = invalid
end sub

' ── Subtitles ───────────────────────────────────────────────────────────────

' Upstream's applySubtitleSelection: shown in fullscreen only, never over the
' guide; always when SUBTITLES is ALWAYS, and with FOREIGN AUDIO only when no
' audio track is in AUDIO LANGUAGE and the subtitles are in SUBTITLE
' LANGUAGE. Otherwise the forced track in SUBTITLE LANGUAGE, when the stream
' carries one as a sidecar (NxMbForcedSub), over the guide too, as upstream
' burns it in. Roku doesn't list a forced track inside the file. On a server
' stream with ALWAYS the full track is a sidecar as well (NxMbFullSub), and
' is picked here as the file's own would be.
sub applySubtitles()
    tracks = NxList(m.video.availableSubtitleTracks)
    tags = []
    forced = []
    sidecar = invalid
    m.hasSubs = false
    for each t in tracks
        tags.Push(NxSubComparableTag(t.Language))
        ' The player keeps a sidecar's Description and puts its own prefix
        ' on the TrackName ("<dev_3_0>http://…").
        isForced = m.tuneForced = true and NxToStr(t.Description) = "Forced" and Instr(1, NxToStr(t.TrackName), "/Subtitles/") > 0
        forced.Push(isForced)
        if isForced then sidecar = t else m.hasSubs = true
    end for
    show = false
    if m.fullscreen and m.hasSubs then
        want = NxSubPreferredLanguage()
        wantAudio = NxAudioPreferredLanguage()
        idx = NxSubPickIndex(tags, forced, want)
        if m.subs.always then
            show = true
        else if m.subs.foreign then
            audio = []
            for each a in NxList(m.video.availableAudioTracks)
                audio.Push(NxSubComparableTag(a.Language))
            end for
            ' Wrong-language subtitles are worse than none, as upstream says.
            if NxSubShouldAutoEnable(audio, wantAudio) and tags[idx] <> invalid then
                show = NxSubMatches(tags[idx], want)
            end if
        end if
        if show then m.video.subtitleTrack = tracks[idx].TrackName
    end if
    if not show and sidecar <> invalid then
        m.video.subtitleTrack = sidecar.TrackName
        print "player: forced subtitles ("; NxToStr(sidecar.Language); ")"
        show = true
    end if
    setCaptions(show)
    refreshNowPlaying()
end sub

' Roku draws subtitles only while its caption mode is on, and that mode is the
' TV's own setting. When it is off, it is turned on just while subtitles show
' and put back afterwards. The old value is saved first, so a launch after
' leaving with Home puts it back too.
sub setCaptions(show as Boolean)
    m.video.suppressCaptions = not show
    reg = NxRegSection("player")
    if show and m.video.globalCaptionMode <> "On" then
        if not reg.Exists("captionModeBefore") then
            reg.Write("captionModeBefore", m.video.globalCaptionMode)
            reg.Flush()
        end if
        m.video.globalCaptionMode = "On"
    else if not show then
        restoreCaptionMode()
    end if
    tracks = NxList(m.video.availableSubtitleTracks)
    print "player: subtitles "; show; " (tracks "; tracks.Count(); ", caption mode "; m.video.globalCaptionMode; ")"
end sub

sub restoreCaptionMode()
    reg = NxRegSection("player")
    if not reg.Exists("captionModeBefore") then return
    m.video.globalCaptionMode = reg.Read("captionModeBefore")
    reg.Delete("captionModeBefore")
    reg.Flush()
end sub

' The CC control of upstream's Now Playing panel, on the * key in fullscreen:
' flips ALWAYS, and says NONE when the airing has no subtitles.
sub toggleCaptions()
    text = "CC  NONE"
    if m.hasSubs then
        m.subs.always = not m.subs.always
        NxSaveSubtitleSettings(m.subs)
        applySubtitles()
        text = "CC  OFF"
        if m.subs.always then text = "CC  ON"
    end if
    toast = m.top.FindNode("ccToast")
    toast.text = text
    toast.visible = true
    if m.toastTimer = invalid then
        m.toastTimer = CreateObject("roSGNode", "Timer")
        m.toastTimer.duration = 3
        m.toastTimer.ObserveField("fire", "onToastTimer")
    end if
    m.toastTimer.control = "stop"
    m.toastTimer.control = "start"
end sub

sub onToastTimer()
    m.top.FindNode("ccToast").visible = false
end sub

' ── Mini channel strip (Up in full screen) ──────────────────────────────────

sub openStrip()
    if m.strip <> invalid or m.tuned < 0 then return
    t = nowSec()
    list = []
    for i = 0 to m.channels.Count() - 1
        ch = m.channels[i]
        b = blockAt(ch, t)
        if i = m.tuned and m.playing <> invalid then b = m.playing
        line = ""
        if b <> invalid then line = musicLine(b)
        list.Push({ number: ch.number, name: ch.name, color: colorOf(ch.color, "FF"), line: line })
    end for
    ' The strip has the bottom of the screen; the OSD would sit under it.
    onOsdTimer()
    m.strip = CreateObject("roSGNode", "MiniStripView")
    m.strip.channels = list
    m.strip.current = m.tuned
    m.strip.ObserveField("picked", "onStripPicked")
    m.strip.ObserveField("closed", "closeStrip")
    m.top.AppendChild(m.strip)
    m.strip.callFunc("open", invalid)
end sub

sub onStripPicked()
    idx = m.strip.picked
    closeStrip()
    m.focus = idx
    keepFocusVisible()
    if idx <> m.tuned then pressTune(idx)
    showOsd()
end sub

sub closeStrip()
    if m.strip = invalid then return
    m.top.RemoveChild(m.strip)
    m.strip = invalid
    m.top.SetFocus(true)
end sub

' ── Now Playing panel (Down in full screen) ─────────────────────────────────

sub openNowPlaying()
    if m.np <> invalid or m.tuned < 0 then return
    m.np = CreateObject("roSGNode", "NowPlayingView")
    m.np.state = npState()
    m.np.ObserveField("action", "onNpAction")
    m.np.ObserveField("closed", "closeNowPlaying")
    m.top.AppendChild(m.np)
    m.np.callFunc("open", invalid)
end sub

sub refreshNowPlaying()
    if m.np <> invalid and m.tuned >= 0 then m.np.state = npState()
end sub

sub closeNowPlaying()
    if m.np = invalid then return
    m.top.RemoveChild(m.np)
    m.np = invalid
    m.top.SetFocus(true)
end sub

' PLAYER SIZE: the picture the player reports, as upstream's
' presentationSize, from the segment it is playing; invalid when it says
' none.
function playerSize() as Object
    seg = m.video.streamingSegment
    if type(seg) = "roAssociativeArray" then return { width: seg.width, height: seg.height }
    return { width: invalid, height: invalid }
end function

' What the panel shows, from the tuned channel, the player and the settings.
function npState() as Object
    ch = m.channels[m.tuned]
    b = m.playing
    st = {
        number: ch.number, name: ch.name, color: colorOf(ch.color, "FF"),
        nowLine: "", rating: "", upNext: "", poster: invalid,
        hasSubs: m.hasSubs, ccOn: m.subs.always, autoOn: m.subs.foreign,
        audio: [], retro: NxRetroMode(), sleepMinutes: 0, sleepLeft: -1, info: [],
        subsLanguage: NxSavedLanguage("subsLanguage"), audioLanguage: NxSavedLanguage("audioLanguage"),
        languages: NxLanguagePresets(),
        quality: NxSqCurrent(), qualities: NxSqLevels()
    }
    st.qualityLabel = NxSqLevel(st.quality).name
    st.subsLabel = NxLanguageShortLabel(st.subsLanguage)
    st.audioLabel = NxLanguageShortLabel(st.audioLanguage)
    if b <> invalid then
        st.nowLine = musicLine(b)
        if not NxTruthy(b.music) and b.year <> "" then st.nowLine = b.title + "  " + b.year
        st.rating = NxToStr(b.contentRating)
        st.poster = NxPosterRef(b, NxSignedInKind())
        nxt = blockAfter(ch, b)
        if nxt <> invalid then st.upNext = musicLine(nxt)
    end if
    ' PLAYBACK INFORMATION, upstream's rows (source/guide/PlaybackInfo.brs).
    if b <> invalid and m.pi <> invalid then
        size = playerSize()
        st.info = NxPiRows(m.pi, size.width, size.height)
        st.infoNote = NxPiEvidenceNote()
    end if
    tracks = NxList(m.video.availableAudioTracks)
    for i = 0 to tracks.Count() - 1
        t = tracks[i]
        name = NxToStr(t.Name)
        if name = "" then name = UCase(NxToStr(t.Language))
        if name = "" then name = "Track " + (i + 1).ToStr()
        st.audio.Push({ name: name, active: NxToStr(t.Track) = NxToStr(m.video.currentAudioTrack) })
    end for
    if m.sleepEnd <> invalid then
        st.sleepMinutes = m.sleepMinutes
        ' Seconds as an Integer: nowSec is a LongInteger.
        st.sleepLeft = (m.sleepEnd - nowSec()).ToStr().ToInt()
    end if
    return st
end function

sub onNpAction()
    a = m.np.action
    if a = "cc" then
        if m.hasSubs then
            m.subs.always = not m.subs.always
            NxSaveSubtitleSettings(m.subs)
            applySubtitles()
        end if
    else if a = "auto" then
        m.subs.foreign = not m.subs.foreign
        NxSaveSubtitleSettings(m.subs)
        applySubtitles()
    else if Left(a, 6) = "audio:" then
        tracks = NxList(m.video.availableAudioTracks)
        n = Mid(a, 7).ToInt()
        if n < tracks.Count() then m.video.audioTrack = tracks[n].Track
    else if a = "retro" then
        NxSaveRetroMode(not NxRetroMode())
        applyRetro()
    else if Left(a, 6) = "sleep:" then
        startSleep(Mid(a, 7).ToInt())
    else if Left(a, 13) = "subsLanguage:" then
        ' Saved as Settings saves it, then applied to what is playing, as
        ' upstream's didSet runs applySubtitleSelection.
        NxSaveLanguage("subsLanguage", Mid(a, 14))
        applySubtitles()
    else if Left(a, 14) = "audioLanguage:" then
        NxSaveLanguage("audioLanguage", Mid(a, 15))
        applyAudioLanguage()
    else if Left(a, 14) = "streamQuality:" then
        ' Saved only: what is playing keeps its stream, and the next
        ' programme is asked for the new level, as upstream's.
        NxSqSave(Mid(a, 15))
        print "player: stream quality set to "; NxSqCurrent()
    end if
    m.np.state = npState()
end sub

' AUDIO LANGUAGE chosen while a film plays: upstream's didSet runs
' applyAudioTrackSelection on it, so the player takes the first track in the
' new language (NxAudioTrackForLanguage), and keeps its own when none is. A
' server stream carries one track, so it takes the new language at the next
' tune. Only a track the player isn't on is set, as applyAudioPick.
sub applyAudioLanguage()
    tracks = NxList(m.video.availableAudioTracks)
    if tracks.Count() < 2 then return
    track = NxAudioTrackForLanguage(tracks, NxAudioPreferredLanguage())
    print "player: audio language "; NxAudioPreferredLanguage(); ", track "; track; ", was "; m.video.currentAudioTrack
    if track <> invalid and NxToStr(track) <> NxToStr(m.video.currentAudioTrack) then m.video.audioTrack = track
end sub

' ── Sleep timer (AppState+Playback's), with its STILL WATCHING? prompt ─────

' Arms the timer for `minutes`; 0 turns it off. It runs across channel
' changes and in the guide too.
sub startSleep(minutes as Integer)
    closeGrace()
    if minutes <= 0 then
        m.sleepEnd = invalid
        m.sleepMinutes = 0
        return
    end if
    m.sleepMinutes = minutes
    m.sleepEnd = nowSec() + minutes * 60
end sub

' Every second: the timer reaching zero shows the prompt for 20 s; the
' prompt running out stops playback and returns to the guide.
sub checkSleep()
    if m.graceEnd <> invalid then
        left = (m.graceEnd - nowSec()).ToStr().ToInt()
        if left <= 0 then
            expireSleep()
        else
            m.top.FindNode("graceCount").text = "SLEEPING IN " + NxSleepCountdown(left)
        end if
    else if m.sleepEnd <> invalid and nowSec() >= m.sleepEnd then
        beginGrace()
    end if
end sub

sub beginGrace()
    m.sleepEnd = invalid
    m.graceEnd = nowSec() + 20
    closeStrip()
    closeNowPlaying()
    m.top.FindNode("graceCount").text = "SLEEPING IN " + NxSleepCountdown(20)
    m.top.FindNode("grace").visible = true
    m.top.SetFocus(true)
end sub

sub keepAwake()
    closeGrace()
    m.sleepMinutes = 0
end sub

sub closeGrace()
    m.graceEnd = invalid
    m.top.FindNode("grace").visible = false
end sub

' Not a sign-out: the stream stops, its transcode is released, and the guide
' comes back, as expireSleepTimer.
sub expireSleep()
    closeGrace()
    m.sleepMinutes = 0
    print "player: sleep timer ran out; stopping"
    ' Nothing waiting may start again behind the guide.
    stopRetry()
    NxTuneDrop(m.tuneQueue)
    stopTracker()
    stopPrevious()
    m.video.control = "stop"
    m.playing = invalid
    setFullscreen(false)
end sub

' Full screen's channel OSD, bottom left, for 8 s (PlayerView's ChannelOSD
' and flashOSD): the channel, what airs, and the time into it, over a
' gradient from black.
sub showOsd()
    if m.tuned < 0 then return
    ch = m.channels[m.tuned]
    color = colorOf(ch.color, "FF")
    g = m.top.FindNode("osd")
    g.RemoveChildrenIndex(g.GetChildCount(), 0)
    content = CreateObject("roSGNode", "Group")
    y = 0
    content.AppendChild(newRect(0, 0, 48, 4, color))
    y = 4 + 8
    lines = [
        { text: "CH " + ch.number.ToStr(), font: "DMMono-Medium", size: 20, color: color },
        { text: ch.name, font: "DMMono-Medium", size: 32, color: "0xFFFFFFFF" }
    ]
    b = m.playing
    if b <> invalid then
        if b.type = "episode" and NxTruthy(b.episodeTitle) then
            lines.Push({ text: b.title + "  " + seTag(b) + "  """ + b.episodeTitle + """", font: "DMMono-Regular", size: 24, color: "0xFFFFFFCC" })
        else if NxTruthy(b.music) then
            lines.Push({ text: b.title, font: "DMMono-Regular", size: 24, color: "0xFFFFFFF2", gap: 4 })
            if NxToStr(b.artist) <> "" then lines.Push({ text: b.artist, font: "DMMono-Regular", size: 24, color: "0xFFFFFFB3", gap: 4 })
            extra = []
            if b.year <> "" then extra.Push(b.year)
            if NxToStr(b.genreLine) <> "" then extra.Push(b.genreLine)
            if extra.Count() > 0 then lines.Push({ text: extra.Join(" "), font: "DMMono-Regular", size: 24, color: "0xFFFFFF8C" })
        else
            line = b.title
            if b.year <> "" then line = line + "  " + b.year
            lines.Push({ text: line, font: "DMMono-Regular", size: 24, color: "0xFFFFFFE6" })
        end if
        lines.Push({ text: "", font: "DMMono-Regular", size: 18, color: "0x8E8E93FF", time: true })
    end if
    widest = 48
    for each l in lines
        lbl = newLabel(l.text, l.font, l.size, l.color, 0, y, 0)
        if l.time = true then
            m.osdTime = lbl
            updateOsdTime()
        end if
        content.AppendChild(lbl)
        r = lbl.boundingRect()
        if r.width > widest then widest = r.width
        gap = 8
        if l.gap <> invalid then gap = l.gap
        y = y + r.height + gap
    end for
    h = y - 8 + 64
    bg = CreateObject("roSGNode", "Poster")
    bg.uri = "pkg:/images/look/osd.png"
    bg.width = widest + 64
    bg.height = h
    g.AppendChild(bg)
    content.translation = [32, 32]
    g.AppendChild(content)
    g.translation = [0, 1080 - h]
    g.visible = true
    if m.osdTimer = invalid then m.osdTimer = newTimer(8, false, "onOsdTimer")
    m.osdTimer.control = "stop"
    m.osdTimer.control = "start"
end sub

sub updateOsdTime()
    if m.osdTime = invalid or m.playing = invalid then return
    t = nowSec()
    m.osdTime.text = hms(t - m.playing.startSec) + " / " + hms(m.playing.endSec - m.playing.startSec)
end sub

sub onOsdTimer()
    m.top.FindNode("osd").visible = false
    m.osdTime = invalid
end sub

' ── Tuning haze: shown when a channel takes more than 0.75 s to start ───────

sub positionHaze()
    bg = m.top.FindNode("hazeBg")
    snow = m.top.FindNode("snow")
    txt = m.top.FindNode("hazeText")
    ' RETRO MODE off sets the text at 24 pt, 33 px tall to 26 pt's 36: down
    ' 1.5 keeps its centre.
    dy = 0
    if not m.retro then dy = 1.5
    if m.fullscreen then
        bg.translation = [0, 0]
        bg.width = 1920
        bg.height = 1080
        snow.translation = [0, 0]
        snow.width = 1920
        snow.height = 1080
        txt.translation = [0, 520 + dy]
        txt.width = 1920
    else
        bg.translation = [1180, 0]
        bg.width = 740
        bg.height = 555
        snow.translation = [1180, 0]
        snow.width = 740
        snow.height = 556
        txt.translation = [1180, 261 + dy]
        txt.width = 740
    end if
end sub

sub armHaze()
    if m.hazeTimer = invalid then m.hazeTimer = newTimer(0.75, false, "onHazeTimer")
    hideHaze()
    m.hazeTimer.control = "stop"
    m.hazeTimer.control = "start"
end sub

' The haze fades in over 0.35 s; its snow starts at 32% and settles to 14%
' after 0.9 s, as StaticScreenView's. With RETRO MODE off it is the plain
' card instead (tuningOverlay in PlayerView and VideoAreaView): black, the
' text at 24 pt and 35%, no snow.
sub onHazeTimer()
    if m.video.state = "playing" or m.tuned < 0 then return
    m.top.FindNode("hazeText").text = "TUNING · CH " + m.channels[m.tuned].number.ToStr()
    if m.retro then
        styleLabel("hazeText", "DMMono-Medium", 26, "0xFFFFFF6B")
    else
        styleLabel("hazeText", "DMMono-Medium", 24, "0xFFFFFF59")
    end if
    positionHaze()
    haze = m.top.FindNode("haze")
    haze.opacity = 0
    haze.visible = true
    snow = m.top.FindNode("snow")
    snow.visible = m.retro
    m.top.FindNode("hazeIn").control = "start"
    if not m.retro then return
    snow.opacity = 0.32
    m.snowTimer.control = "start"
    if m.settleTimer = invalid then m.settleTimer = newTimer(0.9, false, "onSnowSettle")
    m.settleTimer.control = "start"
end sub

sub onSnowTimer()
    m.snowFrame = (m.snowFrame + 1) mod 3
    m.top.FindNode("snow").uri = "pkg:/images/look/snow_" + m.snowFrame.ToStr() + ".png"
end sub

sub onSnowSettle()
    if m.top.FindNode("haze").visible then m.top.FindNode("snowSettle").control = "start"
end sub

sub hideHaze()
    m.top.FindNode("haze").visible = false
    m.snowTimer.control = "stop"
    if m.settleTimer <> invalid then m.settleTimer.control = "stop"
end sub

' ── Packages sidebar (Left on the live slot), as the Apple TV app's ─────────

sub openSidebar()
    m.sideTargets = [{ name: "SETTINGS", channel: -1, color: "#FFE500" }]
    for each b in m.top.guide.bundles
        if NxHasValue(m.top.guide.enabledBundles, b.id) then
            ' FRANCHISES jumps to a found franchise when no classic is shown.
            ids = b.channelIDs
            if b.jumpIDs <> invalid then ids = b.jumpIDs
            for i = 0 to m.channels.Count() - 1
                if NxHasValue(ids, m.channels[i].id) then
                    m.sideTargets.Push({ name: b.name, channel: i, color: m.channels[i].color })
                    exit for
                end if
            end for
        end if
    end for
    m.sideFocus = 1
    if m.sideTargets.Count() = 1 then m.sideFocus = 0
    m.sidebarOpen = true
    renderSidebar()
end sub

sub renderSidebar()
    side = m.top.FindNode("sidebar")
    side.RemoveChildrenIndex(side.GetChildCount(), 0)
    side.AppendChild(newRect(0, 0, 380, 525, "0x080814F2"))
    side.AppendChild(newRect(380, 0, 1, 525, "0xFFFFFF1A"))
    side.AppendChild(newLabel("PACKAGES", "DMMono-Medium", 22, "0xFFFFFF99", 24, 18, 0))
    first = m.sideFocus - 4
    if first < 0 then first = 0
    y = 64
    outline = invalid
    for i = first to m.sideTargets.Count() - 1
        if y > 525 - 72 then exit for
        t = m.sideTargets[i]
        focused = i = m.sideFocus
        color = colorOf(t.color, "FF")
        accentW = 4
        if focused then
            accentW = 8
            side.AppendChild(newRect(0, y, 380, 72, colorOf(t.color, "52")))
            side.AppendChild(newRect(0, y, 8, 72, color))
            ' The grid's outline and glow, drawn over the rows below.
            outline = CreateObject("roSGNode", "Poster")
            outline.uri = "pkg:/images/look/focus.9.png"
            outline.translation = [-16, y - 16]
            outline.width = 412
            outline.height = 104
            outline.blendColor = color
        else
            side.AppendChild(newRect(0, y, 4, 72, colorOf(t.color, "66")))
        end if
        tc = "0xFFFFFFBF"
        if focused then tc = "0xFFFFFFFF"
        x = accentW + 14
        if t.channel < 0 then
            ' SETTINGS: a gear in a 26 px frame, then the name.
            gear = CreateObject("roSGNode", "Poster")
            gear.uri = "pkg:/images/look/gear.png"
            gear.translation = [x + 2, y + 25]
            gear.width = 22
            gear.height = 22
            gear.blendColor = tc
            side.AppendChild(gear)
            x = x + 26 + 14
        end if
        side.AppendChild(newLabel(t.name, "DMMono-Medium", 24, tc, x, y + 20, 360 - x))
        y = y + 74
        if i = 0 then
            side.AppendChild(newRect(16, y + 1, 348, 1, "0xFFFFFF1A"))
            y = y + 10
        end if
    end for
    if outline <> invalid then side.AppendChild(outline)
    side.visible = true
end sub

sub closeSidebar()
    m.sidebarOpen = false
    m.top.FindNode("sidebar").visible = false
end sub

function sidebarKey(key as String) as Boolean
    if key = "down" and m.sideFocus < m.sideTargets.Count() - 1 then
        m.sideFocus = m.sideFocus + 1
        renderSidebar()
    else if key = "up" and m.sideFocus > 0 then
        m.sideFocus = m.sideFocus - 1
        renderSidebar()
    else if key = "right" or key = "back" then
        closeSidebar()
    else if key = "OK" then
        t = m.sideTargets[m.sideFocus]
        closeSidebar()
        if t.channel < 0 then
            openSettings()
        else
            m.focus = t.channel
            setNav("grid")
        end if
    end if
    return true
end function

sub openSettings()
    m.settings = CreateObject("roSGNode", "SettingsView")
    m.settings.bundles = m.top.guide.bundles
    franchises = m.top.guide.franchises
    if franchises = invalid then franchises = []
    m.settings.franchises = franchises
    m.settings.franchiseOverCap = NxNumberOr0(m.top.guide.franchiseOverCap)
    m.settings.franchiseCapacity = NxNumberOr0(m.top.guide.franchiseCapacity)
    collections = m.top.guide.collections
    if collections = invalid then collections = { rows: [], overCap: 0, scanned: 0, failed: 0 }
    m.settings.collections = collections
    m.settings.ObserveField("result", "onSettingsResult")
    m.settings.ObserveField("bundleChange", "onSettingsBundleChange")
    m.settings.ObserveField("rescan", "onSettingsRescan")
    m.settings.rescanning = m.top.libraryBusy
    m.top.AppendChild(m.settings)
    m.settings.callFunc("open", invalid)
    m.settings.callFunc("setBuilding", m.building.Keys())
    m.building = {}
    renderBuildNotice()
end sub

sub onSettingsBundleChange()
    m.top.bundleRequest = true
end sub

sub onBundleBuilt()
    if m.settings <> invalid then
        m.settings.bundleBuilt = m.top.bundleBuilt
        return
    end if
    built = ParseJson(m.top.bundleBuilt)
    if type(built) = "roArray" then
        for each id in built
            m.building.Delete(id)
        end for
        renderBuildNotice()
    else if m.top.bundleBuilt = "rebuild" then
        m.building = {}
        renderBuildNotice()
        ' A build asked for on the way out of Settings couldn't be done in
        ' place: the whole guide is rebuilt, as Settings would have.
        print "guide: the build after Settings needs a full rebuild"
        NxTuneDrop(m.tuneQueue)
        stopPrevious()
        m.tick.control = "stop"
        m.top.action = "rebuild"
    end if
end sub

' The panel's line while packages switched on in Settings are building:
' Settings says it on their rows, and back in the guide nothing did.
sub renderBuildNotice()
    label = m.top.FindNode("buildNotice")
    if m.building.Count() = 0 then
        label.visible = false
        return
    end if
    names = []
    for each b in NxList(m.top.guide.bundles)
        if m.building.DoesExist(b.id) then names.Push(UCase(NxToStr(b.name)))
    end for
    if names.Count() = 1 then
        label.text = "BUILDING " + names[0] + " · ITS CHANNELS SHOW UP WHEN READY"
    else
        label.text = "BUILDING " + m.building.Count().ToStr() + " PACKAGES · THEIR CHANNELS SHOW UP WHEN READY"
    end if
    label.visible = true
end sub

' A guide built while Settings is open: its franchise and collection lists
' go to Settings, so FRANCHISES switched on lists its franchises at once.
sub refreshSettings()
    if m.settings = invalid then return
    if m.top.guide.franchises <> invalid then m.settings.franchises = m.top.guide.franchises
    m.settings.franchiseOverCap = NxNumberOr0(m.top.guide.franchiseOverCap)
    m.settings.franchiseCapacity = NxNumberOr0(m.top.guide.franchiseCapacity)
    if m.top.guide.collections <> invalid then m.settings.collections = m.top.guide.collections
    m.settings.callFunc("refreshRows", invalid)
end sub

sub onSettingsRescan()
    m.top.rescanRequest = true
end sub

sub onLibraryBusy()
    if m.settings <> invalid then m.settings.rescanning = m.top.libraryBusy
end sub

sub onSettingsResult()
    result = m.settings.result
    for each id in m.settings.callFunc("buildingIds", invalid)
        m.building[id] = true
    end for
    renderBuildNotice()
    m.top.RemoveChild(m.settings)
    m.settings = invalid
    linkWaiting = m.linkAfterSettings = true
    m.linkAfterSettings = false
    m.top.SetFocus(true)
    m.subs = NxSubtitleSettings()
    applySubtitles()
    applyRetro()
    applyReportPrefs()
    if applyGuideText() and m.channels <> invalid then renderGrid()
    if result = "rebuild" or result = "signOut" then
        NxTuneDrop(m.tuneQueue)
        stopTracker()
        stopPrevious()
        m.tick.control = "stop"
        m.top.action = result
    else if linkWaiting then
        applyDeepLink()
    end if
end sub

' ── Deep links ──────────────────────────────────────────────────────────────

' A link that comes before the first guide is read by onGuide. One that comes
' while Settings is open waits for it to close; if Settings rebuilds the
' guide, the link is dropped with it.
sub onDeepLink()
    if m.channels = invalid then return
    if m.settings <> invalid then
        m.linkAfterSettings = true
        return
    end if
    applyDeepLink()
end sub

sub applyDeepLink()
    ' No channel to tune or to play a linked item on.
    if m.channels.Count() = 0 then return
    itemId = NxDeepLinkItem(m.top.deepLink, CreateObject("roAppInfo").IsDev())
    if itemId <> "" then
        findLinkedItem(itemId)
        return
    end if
    idx = NxDeepLinkChannel(m.channels, m.top.deepLink)
    if idx < 0 then return
    if m.sidebarOpen = true then closeSidebar()
    m.focus = idx
    m.slotOffset = 0
    setNav("grid")
    if idx <> m.tuned then pressTune(idx)
    setFullscreen(true)
end sub

' A sideloaded build's item link: the item is looked up in the saved library
' (ItemLinkTask), then plays from its start on the channel tuned, or the one
' in focus at launch. When it ends the channel goes on with what airs then.
sub findLinkedItem(id as String)
    print "deep link: looking for item "; id; " in the saved library"
    m.itemTask = CreateObject("roSGNode", "ItemLinkTask")
    m.itemTask.itemId = id
    m.itemTask.ObserveField("airing", "onLinkedItem")
    m.itemTask.control = "run"
end sub

sub onLinkedItem(ev as Object)
    ' A newer link replaced this one.
    if m.itemTask = invalid or not ev.GetRoSGNode().IsSameNode(m.itemTask) then return
    b = ev.GetData()
    id = m.itemTask.itemId
    m.itemTask = invalid
    idx = m.tuned
    if idx < 0 then idx = m.focus
    if b = invalid or b.ratingKey = invalid then
        print "deep link: item "; id; " isn't in the saved library"
        ' A launch link left nothing playing.
        if m.tuned < 0 then pressTune(idx)
        return
    end if
    print "deep link: playing "; b.line; " ("; b.videoCodec; ", "; b.audioCodec; ") on channel "; m.channels[idx].id
    if m.sidebarOpen = true then closeSidebar()
    m.focus = idx
    setNav("grid")
    NxFailureReset(m.failRun)
    m.stopped = false
    m.unplayedEnds = 0
    tune(idx, b)
    setFullscreen(true)
end sub

' ── Remote ──────────────────────────────────────────────────────────────────

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press or m.channels = invalid then return false
    ' Leaving once the stream's stop answers: Back again leaves at once, and
    ' nothing else acts meanwhile.
    if m.leaving = true then return key <> "back"
    ' STILL WATCHING?: any button keeps watching, as SleepGracePrompt.
    if m.graceEnd <> invalid then
        keepAwake()
        return true
    end if
    if m.promptOpen = true then return promptKey(key)
    if m.sidebarOpen = true then return sidebarKey(key)
    if m.fullscreen then
        ' PlayerView's remote: Left/Right change channel with the OSD, Up the
        ' mini channel strip, Down the Now Playing panel, Back the guide (an
        ' open overlay handles its own Back). OK and Play flash the OSD:
        ' this is live TV, nothing pauses.
        if key = "back" then
            setFullscreen(false)
            return true
        end if
        if key = "left" or key = "right" then
            d = 1
            if key = "left" then d = -1
            idx = (m.tuned + d + m.channels.Count()) mod m.channels.Count()
            m.focus = idx
            keepFocusVisible()
            pressTune(idx)
            showOsd()
            return true
        end if
        if key = "up" then
            openStrip()
            return true
        end if
        if key = "down" then
            openNowPlaying()
            return true
        end if
        if key = "OK" or key = "play" then
            ' A channel that stopped trying tries again.
            if m.stopped then pressTune(m.tuned) else showOsd()
            return true
        end if
        if key = "options" then
            toggleCaptions()
            return true
        end if
        return false
    end if
    if key = "options" then
        ' Never passed up to MainScene, where it signs out.
        return true
    end if
    ' Above the grid: the invite row, then SETTINGS, as ChannelGuideView
    ' moves focus up off its first row.
    if m.nav <> "grid" then
        if key = "up" and m.nav = "invite" then
            setNav("settings")
        else if key = "down" and m.nav = "settings" and leadRows() > 0 then
            setNav("invite")
        else if key = "down" then
            m.focus = 0
            setNav("grid")
        else if key = "OK" and m.nav = "settings" then
            openSettings()
        else if key = "OK" and m.nav = "invite" then
            openPrompt()
        else if key = "back" then
            m.focus = m.tuned
            setNav("grid")
        end if
        return true
    end if
    if key = "up" or key = "down" then
        ' Down off the last channel wraps to channel one; Up off channel one
        ' goes to the invite row or SETTINGS (source/guide/GuideNav.brs).
        idx = NxGuideStep(m.focus, m.channels.Count(), key)
        if idx < 0 then
            if leadRows() > 0 then setNav("invite") else setNav("settings")
            return true
        end if
        m.focus = idx
        keepFocusVisible()
        renderGrid()
        renderInfo()
        return true
    end if
    if key = "right" and m.slotOffset < 44 then
        m.slotOffset = m.slotOffset + 1
        renderGrid()
        return true
    end if
    if key = "left" and m.slotOffset > 0 then
        m.slotOffset = m.slotOffset - 1
        renderGrid()
        return true
    end if
    if key = "left" then
        openSidebar()
        return true
    end if
    ' With no channel there is nothing to tune or fill the screen with.
    if m.channels.Count() = 0 and key = "OK" then
        openSettings()
        return true
    end if
    if m.channels.Count() = 0 and (key = "play" or key = "back") then return key <> "back"
    if key = "OK" then
        ' A channel the sleep timer stopped starts again, and one that
        ' stopped trying tries again.
        if m.focus = m.tuned and m.playing <> invalid and not m.stopped then setFullscreen(true) else pressTune(m.focus)
        return true
    end if
    if key = "play" then
        setFullscreen(true)
        return true
    end if
    if key = "back" then
        ' Back returns to the live channel, then leaves (NxGuideBack). A
        ' stop already out for a channel change counts: leaving now would
        ' cut it off.
        stopping = m.tuneQueue.stopping = true
        action = NxGuideBack(m.focus, m.tuned, m.slotOffset, stopping or (m.stopUrl <> invalid and m.stopUrl <> ""))
        if action = "live" then
            m.focus = m.tuned
            m.slotOffset = 0
            keepFocusVisible()
            renderGrid()
            renderInfo()
            return true
        end if
        if action = "stop" then
            print "guide: back, stopping the server's stream before leaving"
            m.leaving = true
            NxTuneDrop(m.tuneQueue)
            stopTracker()
            if not stopping then stopPrevious()
            return true
        end if
        ' Nothing for the server to stop, but a reported programme still
        ' gets its stop and is put back before the app closes.
        if action <> "live" and m.tracker <> invalid and reportingOn() then
            print "guide: back, telling the server playback stopped before leaving"
            m.leaving = true
            NxTuneDrop(m.tuneQueue)
            stopTracker()
            leaveAfterReports()
            return true
        end if
    end if
    return false
end function

' The focused row in the middle of the rows, as tvOS scrolls it (anchor
' .center), held at both ends of the list, and snapped to a whole row at
' the top: centred exactly, 29 px of the row two above showed under the
' time header, below its text, as a bare colour bar (Discussion #8). The
' row cut at the bottom keeps its name.
sub keepFocusVisible()
    at = 0
    if m.nav = "grid" then at = m.focus + leadRows()
    total = m.channels.Count() + leadRows()
    want = (m.viewHeight - 80) \ 2 - at * m.rowPitch
    if want < 0 then want = -(((-want) + m.rowPitch \ 2) \ m.rowPitch) * m.rowPitch
    lowest = m.viewHeight - total * m.rowPitch
    if lowest > 0 then lowest = 0
    if want < lowest then want = lowest
    if want > 0 then want = 0
    m.scrollY = want
end sub

' Focus moves between the grid, the invite row and the SETTINGS nav item.
sub setNav(nav as String)
    m.nav = nav
    if nav = "settings" then
        m.top.FindNode("navSettings").color = "0xFFE500FF"
    else
        m.top.FindNode("navSettings").color = "0xFFFFFF80"
    end if
    keepFocusVisible()
    renderGrid()
    renderInfo()
end sub

' ── Seasonal invite ─────────────────────────────────────────────────────────

sub refreshOffer()
    bundles = m.top.guide.bundles
    if bundles = invalid then bundles = []
    enabled = m.top.guide.enabledBundles
    if enabled = invalid then enabled = []
    m.offer = NxSeasonalOffer(bundles, enabled, NxSeasonNow(), NxSeasonalRegistry())
    if m.offer = invalid and m.nav = "invite" then m.nav = "grid"
end sub

' ChannelGuideView's confirmationDialog: three answers, up and down to choose.
sub openPrompt()
    m.promptFocus = 0
    m.promptOpen = true
    renderPrompt()
end sub

sub renderPrompt()
    g = m.top.FindNode("prompt")
    g.RemoveChildrenIndex(g.GetChildCount(), 0)
    accent = NxSeasonalAccent(m.offer)
    g.AppendChild(newRect(0, 0, 1920, 1080, "0x000000CC"))
    q = newLabel("Add " + NxToStr(m.offer.name) + " to your lineup? It stays on until you switch it off.", "DMMono-Medium", 28, "0xFFFFFFFF", 260, 380, 1400)
    q.horizAlign = "center"
    q.wrap = true
    g.AppendChild(q)
    answers = ["YES, TURN IT ON", "NOT THIS YEAR", "DON'T ASK AGAIN"]
    for i = 0 to 2
        y = 480 + i * 86
        focused = i = m.promptFocus
        if focused then g.AppendChild(newRect(660, y, 600, 72, colorOf(accent, "FF")))
        tc = "0xFFFFFFBF"
        if i = 2 then tc = "0xFF6B6BFF"
        if focused then tc = "0x000000FF"
        a = newLabel(answers[i], "DMMono-Medium", 24, tc, 660, y + 22, 600)
        a.horizAlign = "center"
        g.AppendChild(a)
    end for
    g.visible = true
end sub

function promptKey(key as String) as Boolean
    if key = "up" and m.promptFocus > 0 then
        m.promptFocus = m.promptFocus - 1
        renderPrompt()
    else if key = "down" and m.promptFocus < 2 then
        m.promptFocus = m.promptFocus + 1
        renderPrompt()
    else if key = "back" then
        closePrompt()
    else if key = "OK" then
        answers = ["yes", "notNow", "never"]
        answer = answers[m.promptFocus]
        dt = CreateObject("roDateTime")
        dt.ToLocalTime()
        offer = m.offer
        turnOn = NxSeasonalRegistry().record(answer, offer.id, dt.GetYear())
        closePrompt()
        if turnOn then
            ' On for good, as the Apple TV's toggleBundle, then rebuilt like a
            ' change in Settings.
            enabled = NxEnabledBundles()
            if not NxHasValue(enabled, offer.id) then enabled.Push(offer.id)
            reg = NxRegSection("guide")
            reg.Write("bundles", FormatJson(enabled))
            reg.Flush()
            NxTuneDrop(m.tuneQueue)
            stopPrevious()
            m.tick.control = "stop"
            m.top.action = "rebuild"
        else
            refreshOffer()
            setNav("grid")
        end if
    end if
    return true
end function

sub closePrompt()
    m.promptOpen = false
    m.top.FindNode("prompt").visible = false
end sub
