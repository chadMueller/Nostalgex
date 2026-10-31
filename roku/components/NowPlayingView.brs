' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Upstream's NowPlayingPanel: the info zone (the Plex poster, channel, what's
' on, rating, up next) and two control columns, one for the program (CAPTIONS, AUDIO) and
' one for the device (PICTURE with STREAM QUALITY, SLEEP TIMER, PLAYBACK
' INFORMATION). Left and Right move between the columns, Up and Down within
' one. PLAYBACK INFORMATION, STREAM QUALITY, SUBTITLE LANGUAGE and AUDIO
' LANGUAGE open in place of the columns; Back closes them, then the panel.
'
' Left out, for what the Roku has: OPEN IN PLEX. Rounded corners are
' square; the shade is flat where upstream's fades, and light, with shadowed
' text.

sub init()
    m.fonts = {}
    m.col = 0
    m.idx = [0, 0]
    m.infoOpen = false
    ' The list open in place of the columns: "subsLanguage",
    ' "audioLanguage", "streamQuality", or "".
    m.picker = ""
    m.pickIdx = 0
    m.colX = [992, 1452]
    m.colW = 420
    ' upstream's languageColumn: two columns 380 wide, 20 apart.
    m.langW = 380
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
        if kind = "captionsHeader" then
            prog.Push({ kind: "hdr", label: "CAPTIONS" })
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
            prog.Push({ kind: "row", label: "AUTO SUBTITLES (FOREIGN AUDIO)", value: v, active: s.autoOn, id: "auto" })
        else if kind = "audioHeader" then
            prog.Push({ kind: "hdr", label: "AUDIO" })
        else if kind = "audioTracks" then
            if tracks.Count() <= 1 then
                name = "SINGLE TRACK"
                if tracks.Count() = 1 then name = tracks[0].name
                prog.Push({ kind: "row", label: name, value: "", disabled: true })
            else
                for i = 0 to tracks.Count() - 1
                    v = ""
                    if tracks[i].active then v = "ACTIVE"
                    prog.Push({ kind: "row", label: tracks[i].name, value: v, active: tracks[i].active, id: "audio:" + i.ToStr() })
                end for
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
    dev.Push({ kind: "row", label: "STREAM QUALITY", value: UCase(NxToStr(s.qualityLabel)), id: "pick:streamQuality", note: "Takes effect on the next program." })
    dev.Push({ kind: "hdr", label: "SLEEP TIMER" })
    armed = s.sleepMinutes
    v = ""
    if armed <= 0 then v = "ACTIVE"
    dev.Push({ kind: "row", label: "OFF", value: v, active: armed <= 0, id: "sleep:0" })
    for each minutes in NxSleepOffered(armed)
        on = armed = minutes
        v = ""
        if on then v = NxSleepCountdown(s.sleepLeft)
        dev.Push({ kind: "row", label: NxSleepLabel(minutes), value: v, active: on, id: "sleep:" + minutes.ToStr() })
    end for
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
    renderInfo(s)
    g = m.top.FindNode("controls")
    g.RemoveChildrenIndex(g.GetChildCount(), 0)
    bottom = 0
    if m.infoOpen then
        bottom = renderInformation(g, s)
    else if m.picker = "streamQuality" then
        bottom = renderQualities(g, s)
    else if m.picker <> "" then
        bottom = renderLanguages(g, s)
    else
        cols = columns()
        for c = 0 to 1
            y = 40
            f = focusables(cols[c])
            if m.idx[c] > f.Count() - 1 then m.idx[c] = f.Count() - 1
            for i = 0 to cols[c].Count() - 1
                e = cols[c][i]
                if e.kind = "hdr" then
                    g.AppendChild(newLabel(e.label, "DMMono-Medium", 16, "0xFFFFFF99", m.colX[c], y + 6, 0))
                    y = y + 34
                else
                    focused = c = m.col and f.Count() > 0 and f[m.idx[c]] = i
                    y = y + drawRow(g, m.colX[c], y, e, focused, s.color) + 10
                end if
            end for
            if y > bottom then bottom = y
        end for
    end if
    infoBottom = 40 + 340
    if bottom < infoBottom then bottom = infoBottom
    m.top.FindNode("shade").height = bottom + 32
    shadowLabels(m.top.FindNode("info"))
    shadowLabels(g)
end sub

' The shade is light (about 15%, issue #148), so the video shows through it
' and white text can sit on a bright frame. Each label gets a dark copy 2px
' down and right, drawn under it: a drop shadow, which Label has no field for.
sub shadowLabels(g as Object)
    i = 0
    while i < g.GetChildCount()
        lbl = g.GetChild(i)
        if lbl.Subtype() = "Label" then
            sh = CreateObject("roSGNode", "Label")
            sh.text = lbl.text
            sh.font = lbl.font
            sh.color = "0x000000CC"
            sh.translation = [lbl.translation[0] + 2, lbl.translation[1] + 2]
            sh.width = lbl.width
            sh.horizAlign = lbl.horizAlign
            sh.ellipsizeOnBoundary = lbl.ellipsizeOnBoundary
            sh.wrap = lbl.wrap
            sh.maxLines = lbl.maxLines
            g.InsertChild(sh, i)
            i = i + 1
        end if
        i = i + 1
    end while
end sub

' Draws a row and returns its height: 48, taller for a note, which goes
' inside the row under the label in up to two lines, as upstream's
' controlRow (lineLimit 2).
function drawRow(g as Object, x as Float, y as Float, e as Object, focused as Boolean, color as String, w = 0 as Integer) as Integer
    if w <= 0 then w = m.colW
    fill = "0xFFFFFF24"
    if focused then fill = "0x0D0D12FF"
    back = newRect(x, y, w, 48, fill)
    g.AppendChild(back)
    labelColor = "0xFFFFFFFF"
    if e.disabled = true then labelColor = "0xFFFFFF59"
    g.AppendChild(newLabel(e.label, "DMMono-Medium", 20, labelColor, x + 16, y + 11, w - 140))
    if NxToStr(e.value) <> "" then
        valueColor = "0xFFFFFFBF"
        if e.active = true then valueColor = color
        v = newLabel(e.value, "DMMono-Regular", 18, valueColor, x + 16, y + 13, w - 32)
        v.horizAlign = "right"
        g.AppendChild(v)
    end if
    ' A wrapped label measures its lines only once it is on screen.
    h = 48
    if NxToStr(e.note) <> "" then
        note = newLabel(e.note, "DMMono-Regular", 16, "0xFFFFFF99", x + 16, y + 40, w - 32)
        note.wrap = true
        note.maxLines = 2
        g.AppendChild(note)
        h = 40 + Int(note.BoundingRect().height + 0.5) + 12
        back.height = h
    end if
    border = "0xFFFFFF38"
    if e.active = true then border = tint(color, "80")
    t = 1
    if focused then
        border = color
        t = 2
    end if
    outline(g, x, y, w, h, t, border)
    return h
end function

' STREAM QUALITY in place of the columns, as upstream's pickerZone: the
' title, Settings' line with what the panel adds, and the five levels in one
' column 560 wide, each with its detail, the one in use ACTIVE.
function renderQualities(g as Object, s as Object) as Integer
    x = m.colX[0]
    g.AppendChild(newLabel("STREAM QUALITY", "DMMono-Medium", 16, "0xFFFFFF99", x, 46, 0))
    g.AppendChild(newLabel("Lower this when your connection is slow or shared. Takes effect on the next program.", "DMMono-Regular", 17, "0xFFFFFF99", x, 76, 0))
    y = 112
    levels = NxList(s.qualities)
    for i = 0 to levels.Count() - 1
        on = levels[i].id = NxToStr(s.quality)
        v = ""
        if on then v = "ACTIVE"
        e = { label: UCase(levels[i].name), value: v, active: on, note: levels[i].detail }
        y = y + drawRow(g, x, y, e, i = m.pickIdx, s.color, 560) + 10
    end for
    return y
end function

' SUBTITLE LANGUAGE or AUDIO LANGUAGE in place of the columns, as upstream's
' pickerZone: the title, Settings' wording, and every preset in two columns,
' the saved one ACTIVE.
function renderLanguages(g as Object, s as Object) as Integer
    x = m.colX[0]
    title = "AUDIO LANGUAGE"
    note = "Choose which audio track to prefer when multiple are available."
    saved = NxToStr(s.audioLanguage)
    if m.picker = "subsLanguage" then
        title = "SUBTITLE LANGUAGE"
        note = "Choose which subtitle track to prefer when multiple are available."
        saved = NxToStr(s.subsLanguage)
    end if
    g.AppendChild(newLabel(title, "DMMono-Medium", 16, "0xFFFFFF99", x, 46, 0))
    g.AppendChild(newLabel(note, "DMMono-Regular", 17, "0xFFFFFF99", x, 76, 0))
    top = 112
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
        y = top + r * 58
        drawRow(g, x + c * (m.langW + 20), y, { label: langs[i].label, value: v, active: on }, i = m.pickIdx, s.color, m.langW)
        if y + 58 > bottom then bottom = y + 58
    end for
    return bottom
end function

' Opens a list on its saved choice (upstream's selectedOptionID).
sub openLanguages(key as String)
    m.picker = key
    s = m.top.state
    m.pickIdx = 0
    if key = "streamQuality" then
        levels = NxList(s.qualities)
        for i = 0 to levels.Count() - 1
            if levels[i].id = NxToStr(s.quality) then m.pickIdx = i
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

' Up, Down, OK and Back in STREAM QUALITY's one column.
sub qualityKey(key as String)
    levels = NxList(m.top.state.qualities)
    i = m.pickIdx
    if key = "up" and i > 0 then
        i = i - 1
    else if key = "down" and i < levels.Count() - 1 then
        i = i + 1
    else if key = "OK" then
        if levels.Count() > 0 then m.top.action = "streamQuality:" + levels[i].id
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
    x = m.colX[0]
    w = m.colW * 2 + 40
    g.AppendChild(newLabel("PLAYBACK INFORMATION", "DMMono-Medium", 16, "0xFFFFFF99", x, 46, 0))
    y = 80
    ' Upstream's pickerSubtitle: what the rows can and can't say, where the
    ' language pickers put theirs.
    if NxToStr(s.infoNote) <> "" then
        note = newLabel(s.infoNote, "DMMono-Regular", 17, "0xFFFFFF99", x, 76, w)
        note.wrap = true
        g.AppendChild(note)
        y = 76 + note.BoundingRect().height + 16
    end if
    rows = NxList(s.info)
    if rows.Count() = 0 then
        g.AppendChild(newLabel("Playback information is unavailable.", "DMMono-Regular", 20, "0xFFFFFFCC", x, y, 0))
        y = y + 40
    end if
    for each r in rows
        g.AppendChild(newLabel(UCase(r.label), "DMMono-Medium", 17, "0xFFFFFF99", x, y + 3, 220))
        ' A value wraps, as upstream's fixedSize does: the longer FALLBACK
        ' sentences don't fit one line.
        v = newLabel(NxToStr(r.value), "DMMono-Regular", 21, "0xFFFFFFFF", x + 236, y, w - 236)
        v.wrap = true
        g.AppendChild(v)
        h = v.BoundingRect().height
        if h > 30 then y = y + h + 12 else y = y + 38
    end for
    drawRow(g, x, y + 8, { label: "BACK", value: "" }, true, s.color)
    return y + 8 + 58
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

sub renderInfo(s as Object)
    g = m.top.FindNode("info")
    g.RemoveChildrenIndex(g.GetChildCount(), 0)
    showPoster(s.poster)
    x = 48
    if NxToStr(m.posterPath) <> "" then x = 48 + 150 + 24
    y = 40
    g.AppendChild(newRect(x, y, 48, 4, s.color))
    y = y + 12
    g.AppendChild(newLabel("CH " + NxToStr(s.number), "DMMono-Medium", 23, s.color, x, y, 0))
    y = y + 36
    g.AppendChild(newLabel(NxToStr(s.name), "DMMono-Medium", 30, "0xFFFFFFFF", x, y, 640))
    y = y + 46
    now = newLabel(NxToStr(s.nowLine), "DMMono-Regular", 25, "0xFFFFFFE6", x, y, 0)
    now.width = 640
    now.wrap = true
    now.maxLines = 2
    g.AppendChild(now)
    y = y + now.boundingRect().height + 8
    if NxToStr(s.rating) <> "" then
        g.AppendChild(newLabel(UCase(s.rating), "DMMono-Regular", 18, "0xFFFFFFB3", x, y, 0))
        y = y + 30
    end if
    if NxToStr(s.upNext) <> "" then g.AppendChild(newLabel("UP NEXT: " + s.upNext, "DMMono-Regular", 18, "0xFFFFFFB3", x, y + 4, 640))
end sub

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
    if m.picker = "streamQuality" then
        qualityKey(key)
        return true
    end if
    if m.picker <> "" then
        languageKey(key)
        return true
    end if
    cols = columns()
    f = focusables(cols[m.col])
    if key = "up" and m.idx[m.col] > 0 then
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
