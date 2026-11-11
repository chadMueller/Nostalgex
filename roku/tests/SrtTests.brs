' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Runs source/subtitles/Srt.brs (#237): an SRT text into cues, and the lines
' on screen at a moment. Returns the failure count.

function NxRunSrtTests() as Integer
    r = { pass: 0, fail: 0 }
    lf = Chr(10)
    srt = "1" + lf + "00:00:01,000 --> 00:00:03,500" + lf + "Bonjour." + lf + lf + "2" + lf + "00:01:02,250 --> 00:01:04,000" + lf + "<i>Où est la gare ?</i>" + lf + "{\an8}Là-bas." + lf + lf + "3" + lf + "01:00:00,000 --> 01:00:02,000" + lf + "Merci." + lf
    cues = NxSrtParse(srt)
    NxCheck(r, "three cues", cues.Count().ToStr(), "3")
    NxCheck(r, "the first cue", FormatJson(cues[0]), FormatJson({ startMs: 1000, endMs: 3500, text: "Bonjour." }))
    NxCheck(r, "two lines, markup dropped", cues[1].text, "Où est la gare ?" + lf + "Là-bas.")
    NxCheck(r, "minutes and a fraction", cues[1].startMs.ToStr() + " " + cues[1].endMs.ToStr(), "62250 64000")
    NxCheck(r, "an hour in", cues[2].startMs.ToStr(), "3600000")

    ' On screen at a moment.
    NxCheck(r, "before the first cue", NxSrtTextAt(cues, 999), "")
    NxCheck(r, "at its start", NxSrtTextAt(cues, 1000), "Bonjour.")
    NxCheck(r, "inside it", NxSrtTextAt(cues, 2000), "Bonjour.")
    NxCheck(r, "at its end, gone", NxSrtTextAt(cues, 3500), "")
    NxCheck(r, "between cues", NxSrtTextAt(cues, 30000), "")
    NxCheck(r, "the second, both lines", NxSrtTextAt(cues, 63000), "Où est la gare ?" + lf + "Là-bas.")
    NxCheck(r, "after the last", NxSrtTextAt(cues, 3700000), "")
    NxCheck(r, "no cues", NxSrtTextAt([], 5000), "")
    NxCheck(r, "no list", NxSrtTextAt(invalid, 5000), "")

    ' As servers and rippers write them.
    crlf = Chr(13) + lf
    win = Chr(239) + Chr(187) + Chr(191) + "1" + crlf + "00:00:05.5 --> 00:00:07.25 X1:0 X2:10" + crlf + "Hola" + crlf + crlf
    cues = NxSrtParse(win)
    NxCheck(r, "byte order mark, CR LF, full stops, a short fraction, a position tail", FormatJson(cues), FormatJson([{ startMs: 5500, endMs: 7250, text: "Hola" }]))
    NxCheck(r, "no counter lines", NxSrtParse("00:00:01,000 --> 00:00:02,000" + lf + "A" + lf + lf + "00:00:03,000 --> 00:00:04,000" + lf + "B").Count().ToStr(), "2")
    NxCheck(r, "no blank line between cues", NxSrtParse("1" + lf + "00:00:01,000 --> 00:00:02,000" + lf + "A" + lf + "2" + lf + "00:00:03,000 --> 00:00:04,000" + lf + "B")[1].text, "B")
    NxCheck(r, "a cue of markup alone is left out", NxSrtParse("1" + lf + "00:00:01,000 --> 00:00:02,000" + lf + "<i></i>" + lf).Count().ToStr(), "0")
    NxCheck(r, "a cue that ends before it starts is left out", NxSrtParse("1" + lf + "00:00:05,000 --> 00:00:02,000" + lf + "A" + lf).Count().ToStr(), "0")
    NxCheck(r, "a font tag", NxSrtParse("1" + lf + "00:00:01,000 --> 00:00:02,000" + lf + "<font color=""#ffff00"">Ja</font>" + lf)[0].text, "Ja")
    NxCheck(r, "text that isn't SRT", NxSrtParse("<html>404</html>").Count().ToStr(), "0")
    NxCheck(r, "an empty file", NxSrtParse("").Count().ToStr(), "0")
    NxCheck(r, "not text", NxSrtParse(invalid).Count().ToStr(), "0")

    ' Out of order in the file: in time order here. Two at once: both, in order.
    mixed = NxSrtParse("1" + lf + "00:00:10,000 --> 00:00:12,000" + lf + "second" + lf + lf + "2" + lf + "00:00:01,000 --> 00:00:11,000" + lf + "first" + lf)
    NxCheck(r, "sorted by start", mixed[0].text + "," + mixed[1].text, "first,second")
    NxCheck(r, "two cues at once", NxSrtTextAt(mixed, 10500), "first" + lf + "second")

    ' A long track: 2,000 cues of 3 s, one every 3.5 s. Each is found, and the gaps are empty.
    parts = []
    for i = 0 to 1999
        parts.Push((i + 1).ToStr() + lf + NxSrtTestStamp(i * 3500) + " --> " + NxSrtTestStamp(i * 3500 + 3000) + lf + "line " + i.ToStr() + lf)
    end for
    many = NxSrtParse(parts.Join(lf))
    NxCheck(r, "long: every cue read", many.Count().ToStr(), "2000")
    wrong = 0
    for i = 0 to 1999
        if NxSrtTextAt(many, i * 3500) <> "line " + i.ToStr() then wrong = wrong + 1
        if NxSrtTextAt(many, i * 3500 + 2999) <> "line " + i.ToStr() then wrong = wrong + 1
        if NxSrtTextAt(many, i * 3500 + 3000) <> "" then wrong = wrong + 1
        if NxSrtTextAt(many, i * 3500 + 3499) <> "" then wrong = wrong + 1
    end for
    NxCheck(r, "long: each cue at its start and end, and each gap empty", wrong.ToStr(), "0")
    NxCheck(r, "long: before the first", NxSrtTextAt(many, -1), "")
    NxCheck(r, "long: after the last", NxSrtTextAt(many, 7000000), "")
    ' A line that stays up while 16 shorter ones come and go under it is still found.
    over = [{ startMs: 0, endMs: 100000, text: "long" }]
    for i = 1 to 16
        over.Push({ startMs: i * 1000, endMs: i * 1000 + 500, text: "s" + i.ToStr() })
    end for
    NxCheck(r, "overlap: a long line under 16 short ones", NxSrtTextAt(over, 16100), "long" + lf + "s16")

    ' Where the line is drawn: inside the picture, full screen and in the guide's preview.
    full = NxForcedSubBox(true)
    NxCheck(r, "box: full screen, inside the screen", NxToStr(full.x >= 0 and full.x + full.w <= 1920 and full.y + full.h <= 1080), "true")
    small = NxForcedSubBox(false)
    NxCheck(r, "box: the guide's preview, inside its box", NxToStr(small.x >= 1180 and small.x + small.w <= 1920 and small.y + small.h <= 555), "true")
    NxCheck(r, "box: smaller type in the preview", NxToStr(small.size < full.size), "true")

    ' The moment drawn for: the reported position plus the time since the report.
    NxCheck(r, "moment: just reported", NxForcedSubMs(297.0, 0).ToStr(), "297000")
    NxCheck(r, "moment: 208 ms after the report", NxForcedSubMs(297.0, 208).ToStr(), "297208")
    NxCheck(r, "moment: never more than 600 ms ahead", NxForcedSubMs(297.0, 5000).ToStr(), "297600")
    NxCheck(r, "moment: a clock that ran back adds nothing", NxForcedSubMs(297.5, -3).ToStr(), "297500")
    NxCheck(r, "moment: no position yet", NxForcedSubMs(invalid, 100).ToStr(), "0")

    print "srt cases (#237):"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' ms as an SRT stamp, for the long test track.
function NxSrtTestStamp(ms as Integer) as String
    h = ms \ 3600000
    mi = (ms \ 60000) mod 60
    se = (ms \ 1000) mod 60
    fr = ms mod 1000
    return Right("0" + h.ToStr(), 2) + ":" + Right("0" + mi.ToStr(), 2) + ":" + Right("0" + se.ToStr(), 2) + "," + Right("00" + fr.ToStr(), 3)
end function
