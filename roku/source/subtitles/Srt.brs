' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' A forced subtitle track drawn by the app (#237, option A of #117): the
' server's SRT read into cues, and the lines on screen at a moment of the
' film. Roku's Video node hands an app no subtitle text, and shows its own
' captions only while the TV's caption mode is on, which is the viewer's
' setting and not the app's to change. So a forced track (foreign dialogue in
' a film in the viewer's language) is fetched as SRT, parsed here, and drawn
' in a Label timed off the player's position.

' The cues of an SRT text, in time order: [{ startMs, endMs, text }]. A cue
' is its timing line ("00:01:02,500 --> 00:01:04,000", a full stop for the
' comma too, anything after the end time ignored) and the lines under it up
' to a blank one; the counter line above is not needed. Markup is dropped
' (<i>, <font ...>, {\an8}), lines are joined with a line feed, and a cue
' with no text left or that ends before it starts is left out. A byte order
' mark and CR LF line ends are taken as they come.
function NxSrtParse(text as Dynamic) as Object
    cues = []
    if not NxIsString(text) then return cues
    timing = CreateObject("roRegex", "^\s*(\d+):(\d\d):(\d\d)[,.](\d{1,3})\s*-->\s*(\d+):(\d\d):(\d\d)[,.](\d{1,3})", "")
    markup = CreateObject("roRegex", "<[^>]*>|\{\\[^}]*\}", "")
    lines = text.Replace(Chr(13), "").Split(Chr(10))
    cue = invalid
    ' Whether the line before was one of the cue's, kept: an all-digit one
    ' just before a timing line is the next cue's counter, when the file has
    ' no blank line between the two.
    kept = false
    digits = CreateObject("roRegex", "^\d+$", "")
    for each raw in lines
        line = raw
        ' The byte order mark, as three bytes or as one character.
        if cues.Count() = 0 and cue = invalid then
            if Left(line, 3) = Chr(239) + Chr(187) + Chr(191) then line = Mid(line, 4)
            if Left(line, 1) = Chr(65279) then line = Mid(line, 2)
        end if
        t = timing.Match(line)
        if t.Count() = 9 then
            if kept and digits.IsMatch(cue.lines.Peek()) then cue.lines.Pop()
            kept = false
            NxSrtKeep(cues, cue)
            cue = { startMs: NxSrtMs(t[1], t[2], t[3], t[4]), endMs: NxSrtMs(t[5], t[6], t[7], t[8]), lines: [] }
        else if line.Trim() = "" then
            kept = false
            NxSrtKeep(cues, cue)
            cue = invalid
        else if cue <> invalid then
            cleaned = markup.ReplaceAll(line, "").Trim()
            kept = cleaned <> ""
            if kept then cue.lines.Push(cleaned)
        else
            kept = false
        end if
    end for
    NxSrtKeep(cues, cue)
    ' A file out of time order (rare) is put in order: an insertion sort,
    ' which leaves cues that start together as the file had them.
    for i = 1 to cues.Count() - 1
        c = cues[i]
        j = i - 1
        while j >= 0
            if cues[j].startMs <= c.startMs then exit while
            cues[j + 1] = cues[j]
            j = j - 1
        end while
        cues[j + 1] = c
    end for
    return cues
end function

sub NxSrtKeep(cues as Object, cue as Dynamic)
    if cue = invalid then return
    if cue.lines.Count() = 0 or cue.endMs <= cue.startMs then return
    cues.Push({ startMs: cue.startMs, endMs: cue.endMs, text: cue.lines.Join(Chr(10)) })
end sub

' "1", "02", "03", "5" is 1 h 2 min 3.5 s: a fraction of fewer than three
' digits is tenths or hundredths, as a decimal reads.
function NxSrtMs(h as String, m0 as String, s as String, frac as String) as Integer
    ms = frac.ToInt()
    if Len(frac) = 1 then ms = ms * 100
    if Len(frac) = 2 then ms = ms * 10
    return ((h.ToInt() * 60 + m0.ToInt()) * 60 + s.ToInt()) * 1000 + ms
end function

' What is on screen `ms` into the film: the text of each cue that has
' started and not ended, in order, joined with a line feed, or "" for none.
' The last cue to have started is found by halving, and the 16 before it are
' looked at for lines still up, so a long track costs no more than a short
' one: walking a 2,000-cue list took about 3 ms a look near its end on a
' 43S45, ten times a second.
function NxSrtTextAt(cues as Dynamic, ms as Integer) as String
    list = NxList(cues)
    lo = 0
    hi = list.Count() - 1
    last = -1
    while lo <= hi
        half = (lo + hi) \ 2
        if list[half].startMs <= ms then
            last = half
            lo = half + 1
        else
            hi = half - 1
        end if
    end while
    if last < 0 then return ""
    first = last - 16
    if first < 0 then first = 0
    out = []
    for i = first to last
        if ms < list[i].endMs then out.Push(list[i].text)
    end for
    return out.Join(Chr(10))
end function

' Where a drawn forced line goes: the lower part of the full screen picture,
' or of the guide's preview box (1180,0 740x555), bottom-aligned in the box,
' with the size of its type and how far its dark edge sits behind it.
function NxForcedSubBox(fullscreen as Boolean) as Object
    if fullscreen then return { x: 160, y: 760, w: 1600, h: 250, size: 44, edge: 3 }
    return { x: 1200, y: 385, w: 700, h: 150, size: 22, edge: 2 }
end function

' The moment of the film to draw for: the player's last reported position
' (seconds) plus the time since it reported it, as it reports only every
' half second. No more than 600 ms is added, so a player that has stopped
' reporting (a stall the state hasn't caught up with) isn't run ahead.
function NxForcedSubMs(position as Dynamic, sinceReportMs as Integer) as Integer
    if not NxIsNumber(position) then return 0
    add = sinceReportMs
    if add < 0 then add = 0
    if add > 600 then add = 600
    return Int(position * 1000) + add
end function
