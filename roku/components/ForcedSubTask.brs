' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

sub init()
    m.top.functionName = "fetch"
end sub

' Up to 2 minutes: a server that hasn't made the file yet reads the whole
' video for it (SubtitleWarmTask asks ahead of the airing for that reason).
' The address is never printed.
sub fetch()
    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(port)
    xfer.SetUrl(m.top.url)
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    clock = CreateObject("roTimespan")
    code = "not sent"
    text = ""
    if xfer.AsyncGetToString() then
        msg = Wait(120000, port)
        if type(msg) = "roUrlEvent" then
            code = msg.GetResponseCode().ToStr()
            if msg.GetResponseCode() = 200 then text = msg.GetString()
        else
            code = "no answer"
            xfer.AsyncCancel()
        end if
    end if
    fetched = clock.TotalMilliseconds()
    cues = NxSrtParse(text)
    print "subtitles: forced track "; code; " in "; fetched; " ms, "; Len(text); " characters, "; cues.Count(); " lines read in "; clock.TotalMilliseconds() - fetched; " ms"
    m.top.cues = cues
end sub
