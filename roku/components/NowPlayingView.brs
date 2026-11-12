' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Upstream's NowPlayingPanel: the info zone (the Plex poster, channel, what's
' on, rating, up next) and two control columns, one for the program (CAPTIONS, AUDIO) and
' one for the device (PICTURE with STREAM QUALITY, SLEEP TIMER, PLAYBACK
' INFORMATION). Left and Right move between the columns, Up and Down within
' one. PLAYBACK INFORMATION, STREAM QUALITY, SUBTITLE LANGUAGE and AUDIO
' LANGUAGE open in place of the columns; Back closes them, then the panel.
'
' Laid out as the Apple TV 1.0.32's (#266): the panel colour at 96% fading out
' at the foot, two columns 440 wide with 64 px rows and the hint line under
' them (NxPanelMetrics, NxPanelHint). Up on the first row of a column closes
' it, as Down opened it (NxOverlayKey). Left out, for what the Roku has: OPEN
' IN PLEX. Rounded corners are square.

sub init()
    m.fonts = {}
    m.tk = NxTokens()
    m.col = 0
    m.idx = [0, 0]
    m.infoOpen = false
    ' The list open in place of the columns: "subsLanguage",
    ' "audioLanguage", "streamQuality", or "".
    m.picker = ""
    m.pickIdx = 0
    ' Two columns 440 wide, 28 apart, 90 from the right edge (NxPanelMetrics).
    pm = NxPanelMetrics()
    m.colW = pm.colW
    m.colX = [1920 - pm.safeX - 2 * pm.colW - pm.colGap, 1920 - pm.safeX - pm.colW]
    ' upstream's languageColumn: the same two columns.
    m.langW = pm.colW
    m.focusRects = []
    m.hint = ""
end sub

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

function newLabel(text as String, font as String, size as Integer, color as String, x as Float, y as Float, width as Float) as Object
    lbl = CreateObject("roSGNode", "Label")
    lbl.text = text
    lbl.font = fontOf(font, size)
    lbl.color = color
    lbl.translation = [x, y]
    if width > 0 then
        lbl.width = width
        lbl.ellipsizeOnBoundary = true
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

sub outline(g as Object, x as Float, y as Float, w as Float, h as Float, t as Float, color as String)
    g.AppendChild(newRect(x, y, w, t, color))
    g.AppendChild(newRect(x, y + h - t, w, t, color))
    g.AppendChild(newRect(x, y, t, h, color))
    g.AppendChild(newRect(x + w - t, y, t, h, color))
end sub

' A rounded capsule of one colour (images/look/capsule.9.png).
function newCapsule(x as Float, y as Float, w as Float, h as Float, color as String) as Object
    p = CreateObject("roSGNode", "Poster")
    p.uri = "pkg:/images/look/capsule.9.png"
    p.translation = [x, y]
    p.width = w
    p.height = h
    p.blendColor = color
    return p
end function

' A dashed outline, 10 on and 6 off.
sub dashes(g as Object, x as Float, y as Float, w as Float, h as Float, t as Float, color as String)
    d = 0
    while d < w
        n = 10
        if d + n > w then n = w - d
        g.AppendChild(newRect(x + d, y, n, t, color))
        g.AppendChild(newRect(x + d, y + h - t, n, t, color))
        d = d + 16
    end while
    d = 0
    while d < h
        n = 10
        if d + n > h then n = h - d
        g.AppendChild(newRect(x, y + d, t, n, color))
        g.AppendChild(newRect(x + w - t, y + d, t, n, color))
        d = d + 16
    end while
end sub

function tint(color as String, alpha as String) as String
    return Left(color, 8) + alpha
end function

sub setInfoOpen(isOpen as Boolean)
    m.infoOpen = isOpen
    m.top.infoOpen = isOpen
end sub

sub open(unused = invalid as Dynamic)
    m.col = 0
    m.idx = [0, 0]
    setInfoOpen(false)
    m.picker = ""
    ' Upstream opens on CC (focusedControl = .cc) even with no subtitles,
    ' where it's greyed out; here it opens on the next row that does
    ' something instead: an audio track, else RETRO MODE (Discussion #8).
    if m.top.state <> invalid then
        cols = columns()
        f = focusables(cols[0])
        if f.Count() > 0 and cols[0][f[0]].disabled = true then
            if f.Count() > 1 then m.idx[0] = 1 else m.col = 1
        end if
    end if
    render()
    m.top.SetFocus(true)
end sub

' The two columns as lists of { kind: hdr | row, label, value, active,
' disabled, id, note }; only rows with an id take focus.
function columns() as Object
    s = m.top.state
    tracks = NxList(s.audio)
    prog = []
    ' In upstream's order (NxPanelProgramRows).
    for each kind in NxPanelProgramRows(s.hasSubs = true, tracks.Count())
        if kind = "header" then
            prog.Push({ kind: "hdr", label: "AUDIO & CAPTIONS" })
        else if kind = "captions" then
            cc = "NONE"
            if s.hasSubs then
                cc = "OFF"
                if s.ccOn then cc = "ON"
            end if
            ' Always focusable, as upstream's, so the panel always opens on it.
            prog.Push({ kind: "row", label: "CC", value: cc, active: s.hasSubs and s.ccOn, disabled: not s.hasSubs, id: "cc" })
        else if kind = "subtitleLanguage" then
            prog.Push({ kind: "row", label: "SUBTITLE LANGUAGE", value: NxToStr(s.subsLabel), id: "pick:subsLanguage" })
        else if kind = "autoSubtitles" then
            v = "OFF"
            if s.autoOn then v = "ON"
            prog.Push({ kind: "row", label: "AUTO SUBTITLES", value: v, active: s.autoOn, id: "auto" })
        else if kind = "audio" then
            ' One row: the current track, opening the list; with one track or
            ' none a plain row the focus skips (upstream's audioRow).
            if NxAudioRowOpensList(tracks.Count()) then
                cur = NxToStr(tracks[0].name)
                for each t in tracks
                    if t.active = true then cur = NxToStr(t.name)
                end for
                prog.Push({ kind: "row", label: "AUDIO", value: cur, id: "pick:audioTracks" })
            else
                name = "SINGLE TRACK"
                if tracks.Count() = 1 then name = tracks[0].name
                prog.Push({ kind: "row", label: name, value: "", disabled: true })
            end if
        else if kind = "audioLanguage" then
            prog.Push({ kind: "row", label: "AUDIO LANGUAGE", value: NxToStr(s.audioLabel), id: "pick:audioLanguage" })
        end if
    end for

    dev = []
    dev.Push({ kind: "hdr", label: "PICTURE" })
    v = "OFF"
    if s.retro then v = "ON"
    dev.Push({ kind: "row", label: "RETRO MODE", value: v, active: s.retro, id: "retro" })
    ' Upstream's streamQualityRow: shown for every programme, with the one
    ' thing its value can't say.
    dev.Push({ kind: "row", label: "STREAM QUALITY", value: UCase(NxToStr(s.qualityLabel)), id: "pick:streamQuality" })
    ' SLEEP TIMER is one row opening its list in place (upstream's sleepRow).
    armed = s.sleepMinutes
    v = "OFF"
    if armed > 0 then v = NxSleepCountdown(s.sleepLeft)
    dev.Push({ kind: "row", label: "SLEEP TIMER", value: v, active: armed > 0, id: "pick:sleep" })
    dev.Push({ kind: "row", label: "PLAYBACK INFORMATION", value: "VIEW", id: "info" })
    return [prog, dev]
end function

function focusables(col as Object) as Object
    out = []
    for i = 0 to col.Count() - 1
        if col[i].id <> invalid then out.Push(i)
    end for
    return out
end function

sub render()
    s = m.top.state
    if s = invalid then return
    pm = NxPanelMetrics()
    infoBottom = renderInfo(s)
    g = m.top.FindNode("controls")
    g.RemoveChildrenIndex(g.GetChildCount(), 0)
    m.focusRects = []
    m.hint = ""
    bottom = 0
    if m.infoOpen then
        bottom = renderInformation(g, s)
    else if m.picker <> "" then
        bottom = renderList(g, s)
    else
        cols = columns()
        for c = 0 to 1
            y = pm.safeY
            f = focusables(cols[c])
            if m.idx[c] > f.Count() - 1 then m.idx[c] = f.Count() - 1
            for i = 0 to cols[c].Count() - 1
                e = cols[c][i]
                if e.kind = "hdr" then
                    y = y + drawHeader(g, m.colX[c], y, e.label, m.colW)
                else
                    focused = c = m.col and f.Count() > 0 and f[m.idx[c]] = i
                    if focused then m.hint = NxPanelHint(e.id)
                    y = y + drawRow(g, m.colX[c], y, e, focused, m.colW) + pm.rowGap
                end if
            end for
            if y > bottom then bottom = y
        end for
    end if
    ' The hint line under the controls: a fixed two-line slot, so the panel
    ' never changes height as the focus moves.
    hint = newLabel(m.hint, m.tk.font.text, pm.text, m.tk.color.text2, m.colX[0], bottom + 8, 2 * pm.colW + pm.colGap)
    hint.wrap = true
    hint.maxLines = 2
    g.AppendChild(hint)
    bottom = bottom + 8 + pm.hintH
    ' The focused row's glow goes over its neighbours.
    for each r in m.focusRects
        g.AppendChild(focusGlow(r[0], r[1], r[2], r[3]))
    end for
    if bottom < infoBottom then bottom = infoBottom
    total = bottom + pm.padBottom
    ' The panel colour at 96% to 85% of the height, then fading out.
    solid = Int(total * 0.85)
    m.top.FindNode("shade").height = solid
    fade = m.top.FindNode("fade")
    fade.RemoveChildrenIndex(fade.GetChildCount(), 0)
    bands = 8
    bh = (total - solid) / bands
    for k = 0 to bands - 1
        a = Int(245 * (bands - 1 - k) / bands)
        digits = "0123456789ABCDEF"
        fade.AppendChild(newRect(0, solid + k * bh, 1920, bh + 1, Left(m.tk.color.panel, 8) + Mid(digits, a \ 16 + 1, 1) + Mid(digits, a mod 16 + 1, 1)))
    end for
end sub

' A group label (upstream's groupLabel): the title in text-2 over a 2 px
' resting-outline rule. Returns the height it takes.
function drawHeader(g as Object, x as Float, y as Float, text as String, w as Float) as Integer
    pm = NxPanelMetrics()
    g.AppendChild(newLabel(text, m.tk.font.label, pm.text, m.tk.color.text2, x, y, w))
    g.AppendChild(newRect(x, y + 36, w, 2, m.tk.color.restingOutline))
    return 46
end function

' The cyan outline and glow of the row under the cursor (images/look/focus.9.png).
function focusGlow(x as Float, y as Float, w as Float, h as Float) as Object
    p = CreateObject("roSGNode", "Poster")
    p.uri = "pkg:/images/look/focus.9.png"
    p.translation = [x - 16, y - 16]
    p.width = w + 32
    p.height = h + 32
    p.blendColor = m.tk.color.cyan
    return p
end function

' Draws a row (upstream's PanelRow) and returns its height, 64: the label at
' the left, the value at the right, a chevron after it on a row that opens a
' list. A resting row is the row fill with a 2 px resting outline; the one
' under the cursor the selected fill with a 3 px cyan outline and glow. Text
' is white or text-2 and nothing else; ON, ACTIVE and a running timer are cyan.
function drawRow(g as Object, x as Float, y as Float, e as Object, focused as Boolean, w = 0 as Integer) as Integer
    pm = NxPanelMetrics()
    tk = m.tk
    if w <= 0 then w = m.colW
    h = pm.rowH
    if focused then
        g.AppendChild(newRect(x, y, w, h, tk.color.selectedRow))
        outline(g, x, y, w, h, tk.row.selectedOutline, tk.color.cyan)
        m.focusRects.Push([x, y, w, h])
        if NxToStr(e.note) <> "" then m.hint = e.note
    else if e.disabled = true and e.id = invalid then
        ' A row that only informs: no fill, a dashed outline (upstream's isStatic).
        dashes(g, x, y, w, h, tk.row.outline, tk.color.restingOutline)
    else
        g.AppendChild(newRect(x, y, w, h, tk.color.row))
        outline(g, x, y, w, h, tk.row.outline, tk.color.restingOutline)
    end if
    right = x + w - pm.padX
    opens = e.id <> invalid and (Left(NxToStr(e.id), 5) = "pick:" or e.id = "info")
    if opens then
        chev = newLabel(">", tk.font.label, pm.text, tk.color.text2, right - 20, y + 17, 20)
        if focused then chev.color = tk.color.cyan
        chev.horizAlign = "right"
        g.AppendChild(chev)
        right = right - 28
    end if
    labelColor = tk.color.text
    if e.disabled = true then labelColor = tk.color.text2
    valueW = 0
    if e.check = true then
        ' The track in use: a cyan check at the right, as upstream's .check.
        tick = CreateObject("roSGNode", "Poster")
        tick.uri = "pkg:/images/look/step_check.png"
        tick.translation = [right - 22, y + (h - 22) \ 2]
        tick.width = 22
        tick.height = 22
        tick.blendColor = tk.color.cyan
        g.AppendChild(tick)
        right = right - 34
    end if
    if NxToStr(e.value) <> "" then
        valueColor = tk.color.text2
        if focused then valueColor = tk.color.text
        font = tk.font.text
        if e.active = true or e.value = "ON" or e.value = "ACTIVE" then
            valueColor = tk.color.cyan
            font = tk.font.label
        end if
        v = newLabel(e.value, font, pm.text, valueColor, x + pm.padX, y + 17, right - x - pm.padX)
        v.horizAlign = "right"
        g.AppendChild(v)
        valueW = Len(e.value) * 13.2 + 12
    end if
    g.AppendChild(newLabel(e.label, tk.font.label, pm.text, labelColor, x + pm.padX, y + 17, right - x - pm.padX - valueW))
    return h
end function

' The list open in place of the columns (upstream's pickerZone): its title
' over the rule, Settings' wording under it, and its rows. STREAM QUALITY and
' SLEEP TIMER are one column; the two language lists are two, the saved choice
' ACTIVE in each.
function renderList(g as Object, s as Object) as Integer
    pm = NxPanelMetrics()
    x = m.colX[0]
    wide = 2 * pm.colW + pm.colGap
    if m.picker = "streamQuality" or m.picker = "sleep" or m.picker = "audioTracks" then
        items = singleItems(s)
        title = "STREAM QUALITY"
        note = "Lower this when your connection is slow or shared. Takes effect on the next program."
        if m.picker = "sleep" then
            title = "SLEEP TIMER"
            note = "Back returns to the panel. Pick OFF to cancel a running timer."
        else if m.picker = "audioTracks" then
            title = "AUDIO"
            note = NxPanelHint("pick:audioTracks")
        end if
        y = pm.safeY + drawHeader(g, x, pm.safeY, title, wide)
        y = y + noteLine(g, note, x, y, wide)
        for i = 0 to items.Count() - 1
            y = y + drawRow(g, x, y, items[i], i = m.pickIdx, pm.colW) + pm.rowGap
        end for
        return y
    end if
    title = "AUDIO LANGUAGE"
    note = "Choose which audio track to prefer when multiple are available."
    saved = NxToStr(s.audioLanguage)
    if m.picker = "subsLanguage" then
        title = "SUBTITLE LANGUAGE"
        note = "Choose which subtitle track to prefer when multiple are available."
        saved = NxToStr(s.subsLanguage)
    end if
    top = pm.safeY + drawHeader(g, x, pm.safeY, title, wide)
    top = top + noteLine(g, note, x, top, wide)
    langs = NxList(s.languages)
    split = (langs.Count() + 1) \ 2
    bottom = top
    for i = 0 to langs.Count() - 1
        c = 0
        r = i
        if i >= split then
            c = 1
            r = i - split
        end if
        on = langs[i].code = saved
        v = ""
        if on then v = "ACTIVE"
        y = top + r * (pm.rowH + pm.rowGap)
        drawRow(g, x + c * (pm.colW + pm.colGap), y, { label: langs[i].label, value: v, active: on }, i = m.pickIdx, pm.colW)
        if y + pm.rowH + pm.rowGap > bottom then bottom = y + pm.rowH + pm.rowGap
    end for
    return bottom
end function

' The words under a list's title, in text-2; returns the height they take.
function noteLine(g as Object, text as String, x as Float, y as Float, w as Float) as Integer
    pm = NxPanelMetrics()
    lbl = newLabel(text, m.tk.font.text, pm.text, m.tk.color.text2, x, y, w)
    lbl.wrap = true
    lbl.maxLines = 2
    g.AppendChild(lbl)
    return 76
end function

' The rows of a one-column list: STREAM QUALITY's levels with their detail
' (the hint line while a row is under the cursor), or SLEEP TIMER's OFF and
' the minutes on offer, the running one with its countdown.
function singleItems(s as Object) as Object
    out = []
    if m.picker = "sleep" then
        armed = s.sleepMinutes
        v = ""
        if armed <= 0 then v = "ACTIVE"
        out.Push({ label: "OFF", value: v, active: armed <= 0, minutes: 0 })
        for each minutes in NxSleepOffered(armed)
            on = armed = minutes
            v = ""
            if on then v = NxSleepCountdown(s.sleepLeft)
            out.Push({ label: NxSleepLabel(minutes), value: v, active: on, minutes: minutes })
        end for
        return out
    end if
    if m.picker = "audioTracks" then
        tracks = NxList(s.audio)
        for i = 0 to tracks.Count() - 1
            out.Push({ label: NxToStr(tracks[i].name), value: "", active: tracks[i].active = true, check: tracks[i].active = true, track: i })
        end for
        return out
    end if
    levels = NxList(s.qualities)
    for i = 0 to levels.Count() - 1
        on = levels[i].id = NxToStr(s.quality)
        v = ""
        if on then v = "ACTIVE"
        out.Push({ label: UCase(levels[i].name), value: v, active: on, note: levels[i].detail, qid: levels[i].id })
    end for
    return out
end function

' Opens a list on its saved choice (upstream's selectedOptionID).
sub openLanguages(key as String)
    m.picker = key
    s = m.top.state
    m.pickIdx = 0
    if key = "streamQuality" or key = "sleep" or key = "audioTracks" then
        items = singleItems(s)
        for i = 0 to items.Count() - 1
            if items[i].active = true then m.pickIdx = i
        end for
        render()
        return
    end if
    saved = NxToStr(s.audioLanguage)
    if key = "subsLanguage" then saved = NxToStr(s.subsLanguage)
    langs = NxList(s.languages)
    for i = 0 to langs.Count() - 1
        if langs[i].code = saved then m.pickIdx = i
    end for
    render()
end sub

' Closes the list, with focus back on the row that opened it, in whichever
' column, as upstream's collapsePicker.
sub closeLanguages()
    owner = "pick:" + m.picker
    m.picker = ""
    cols = columns()
    for c = 0 to 1
        f = focusables(cols[c])
        for k = 0 to f.Count() - 1
            if cols[c][f[k]].id = owner then
                m.col = c
                m.idx[c] = k
            end if
        end for
    end for
    render()
end sub

' Up, Down, OK and Back in a one-column list (STREAM QUALITY, SLEEP TIMER).
sub qualityKey(key as String)
    items = singleItems(m.top.state)
    i = m.pickIdx
    if key = "up" and i > 0 then
        i = i - 1
    else if key = "down" and i < items.Count() - 1 then
        i = i + 1
    else if key = "OK" then
        if items.Count() > 0 then
            if m.picker = "sleep" then
                m.top.action = "sleep:" + items[i].minutes.ToStr()
            else if m.picker = "audioTracks" then
                m.top.action = "audio:" + items[i].track.ToStr()
            else
                m.top.action = "streamQuality:" + items[i].qid
            end if
        end if
        closeLanguages()
        return
    else if key = "back" then
        closeLanguages()
        return
    end if
    if i <> m.pickIdx then
        m.pickIdx = i
        render()
    end if
end sub

' Up, Down, Left, Right, OK and Back in a language list.
sub languageKey(key as String)
    langs = NxList(m.top.state.languages)
    n = langs.Count()
    split = (n + 1) \ 2
    i = m.pickIdx
    if key = "up" then
        if i <> 0 and i <> split then i = i - 1
    else if key = "down" then
        if i <> split - 1 and i < n - 1 then i = i + 1
    else if key = "right" then
        if i < split and i + split < n then i = i + split
    else if key = "left" then
        if i >= split then i = i - split
    else if key = "OK" then
        if n > 0 then m.top.action = m.picker + ":" + langs[i].code
        closeLanguages()
        return
    else if key = "back" then
        closeLanguages()
        return
    end if
    if i <> m.pickIdx then
        m.pickIdx = i
        render()
    end if
end sub

' PLAYBACK INFORMATION in place of the columns, with BACK under it.
function renderInformation(g as Object, s as Object) as Integer
    pm = NxPanelMetrics()
    tk = m.tk
    x = m.colX[0]
    w = 2 * pm.colW + pm.colGap
    y = pm.safeY + drawHeader(g, x, pm.safeY, "PLAYBACK INFORMATION", w)
    ' Upstream's pickerSubtitle: what the rows can and can't say, where the
    ' language pickers put theirs.
    if NxToStr(s.infoNote) <> "" then
        note = newLabel(s.infoNote, tk.font.text, pm.text, tk.color.text2, x, y, w)
        note.wrap = true
        g.AppendChild(note)
        y = y + note.BoundingRect().height + 16
    end if
    rows = NxList(s.info)
    if rows.Count() = 0 then
        g.AppendChild(newLabel("Playback information is unavailable.", tk.font.text, pm.text, tk.color.text, x, y, 0))
        y = y + 40
    end if
    for each r in rows
        g.AppendChild(newLabel(UCase(r.label), tk.font.label, pm.text, tk.color.text2, x, y, 260))
        ' A value wraps, as upstream's fixedSize does: the longer FALLBACK
        ' sentences don't fit one line.
        v = newLabel(NxToStr(r.value), tk.font.text, pm.text, tk.color.text, x + 280, y, w - 280)
        v.wrap = true
        g.AppendChild(v)
        h = v.BoundingRect().height
        if h > 30 then y = y + h + 12 else y = y + 38
    end for
    y = y + 8
    drawRow(g, x, y, { label: "BACK", value: "" }, true, pm.colW)
    return y + pm.rowH + pm.rowGap
end function

' The poster for what is on (NxPosterRef), fetched again only when that
' changes. The info zone sits right of it, as upstream's HStack (spacing 24).
sub showPoster(ref as Dynamic)
    path = ""
    if ref <> invalid then path = NxToStr(ref.path)
    if path = NxToStr(m.posterPath) then return
    m.posterPath = path
    m.top.FindNode("poster").visible = false
    m.top.FindNode("posterBack").visible = path <> ""
    if m.posterTask <> invalid then
        m.posterTask.UnobserveField("file")
        m.posterTask = invalid
    end if
    if path = "" then return
    m.posterTask = CreateObject("roSGNode", "PosterTask")
    m.posterTask.ObserveField("file", "onPosterFile")
    m.posterTask.ref = ref
    m.posterTask.control = "run"
end sub

sub onPosterFile()
    file = m.posterTask.file
    if file = "" then return
    p = m.top.FindNode("poster")
    p.uri = file
    p.visible = true
end sub

function renderInfo(s as Object) as Integer
    ' The Apple TV's Variant A (#266, #262's tokens): the poster 120 by 180 with
    ' the info beside it, which is only the channel line and the programme's
    ' title, then UP NEXT as one line under it: the next title and, straight
    ' after it, a cyan badge saying how many minutes away it is.
    tk = m.tk
    pm = NxPanelMetrics()
    g = m.top.FindNode("info")
    g.RemoveChildrenIndex(g.GetChildCount(), 0)
    showPoster(s.poster)
    x = pm.safeX
    if NxToStr(m.posterPath) <> "" then x = pm.safeX + pm.posterW + pm.posterGap
    w = m.colX[0] - pm.zoneGap - x
    y = pm.safeY
    ' The channel's colour bar beside CH n (VT323 28, white) and the name in capitals (22, text-2).
    g.AppendChild(newRect(x, y + 4, 8, 24, s.color))
    tag = newLabel("CH " + NxToStr(s.number), tk.font.tag, pm.tag, tk.color.text, x + 18, y, 0)
    g.AppendChild(tag)
    nameX = x + 18 + tag.boundingRect().width + 14
    g.AppendChild(newLabel(UCase(NxToStr(s.name)), tk.font.label, pm.text, tk.color.text2, nameX, y + 3, x + w - nameX))
    y = y + 44
    title = newLabel(NxToStr(s.title), tk.font.label, pm.title, tk.color.text, x, y, w)
    title.wrap = true
    title.maxLines = 3
    g.AppendChild(title)
    y = y + title.boundingRect().height + 16
    if NxToStr(s.upNext) <> "" then
        badgeText = NxUpNextBadge(s.upNextIn)
        adv = Len(badgeText) * 13.2
        chipW = adv + 28
        chipX = x + w - chipW
        ' The title takes what the badge leaves and is cut with an ellipsis; the badge is always whole.
        nextLbl = newLabel(NxToStr(s.upNext), tk.font.label, pm.text, tk.color.text, x, y + 5, w - chipW - 16)
        g.AppendChild(nextLbl)
        tw = nextLbl.boundingRect().width
        if tw < w - chipW - 16 then chipX = x + tw + 14
        ' A capsule: the cyan one, the selected-row fill 2 px inside it.
        g.AppendChild(newCapsule(chipX, y, chipW, 36, tk.color.cyan))
        g.AppendChild(newCapsule(chipX + 2, y + 2, chipW - 4, 32, tk.color.selectedRow))
        chip = newLabel(badgeText, tk.font.label, pm.text, tk.color.cyan, chipX, y + 5, chipW)
        chip.horizAlign = "center"
        g.AppendChild(chip)
        y = y + 36
    end if
    bottom = pm.safeY + pm.posterH
    if y > bottom then bottom = y
    return bottom
end function

function onKeyEvent(key as String, press as Boolean) as Boolean
    if not press then return false
    if m.infoOpen then
        ' Back, or OK on BACK, returns to the columns, on the information row.
        if key = "back" or key = "OK" then
            setInfoOpen(false)
            render()
        end if
        return true
    end if
    if m.picker = "streamQuality" or m.picker = "sleep" or m.picker = "audioTracks" then
        qualityKey(key)
        return true
    end if
    if m.picker <> "" then
        languageKey(key)
        return true
    end if
    cols = columns()
    f = focusables(cols[m.col])
    if NxOverlayKey("panel", key, m.idx[m.col] = 0, false) = "close" then
        ' Up with nowhere to go: the reverse of Down, which opened the panel.
        m.top.closed = true
    else if key = "up" and m.idx[m.col] > 0 then
        m.idx[m.col] = m.idx[m.col] - 1
        render()
    else if key = "down" and m.idx[m.col] < f.Count() - 1 then
        m.idx[m.col] = m.idx[m.col] + 1
        render()
    else if (key = "left" and m.col = 1) or (key = "right" and m.col = 0) then
        ' To the other column, at about the same height.
        other = 1 - m.col
        of = focusables(cols[other])
        target = 0
        here = f[m.idx[m.col]]
        for k = 0 to of.Count() - 1
            if of[k] <= here then target = k
        end for
        m.col = other
        m.idx[other] = target
        render()
    else if key = "OK" then
        id = cols[m.col][f[m.idx[m.col]]].id
        if id = "info" then
            setInfoOpen(true)
            render()
        else if Left(id, 5) = "pick:" then
            openLanguages(Mid(id, 6))
        else
            m.top.action = id
        end if
    else if key = "back" then
        m.top.closed = true
    end if
    return true
end function
