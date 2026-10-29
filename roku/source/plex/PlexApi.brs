' Plex sign-in and server discovery: plex.tv's PIN link, as upstream's web
' tuner does it (plex-tuner.html startPlexAuth / discoverServers).
'
' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Security rules for everything in this file:
'   - HTTPS, with certificates verified, to plex.tv. To the Plex server, the
'     server's plain-HTTP home-network address when one answered as that
'     server (source/plex/ServerResolve.brs), else HTTPS: on networks like
'     the developer's, the public route stalls video and drops library
'     reads, and the secure in-house address doesn't resolve. That address
'     must be private (NxIsPrivateHost); the token then crosses the home
'     network only.
'   - The token lives only in this app's registry section. It is never
'     printed: the debug console (port 8085) is readable by anyone on the
'     network. Print the status, never a URL or header that carries a token.
'   - Sign-out (NxPlexClearAuth) removes everything this file stores.
'
' Network calls block, so these run in a Task node, never the render thread.

' ── Stored state ────────────────────────────────────────────────────────────

function NxPlexRegistry() as Object
    return NxRegSection("plex")
end function

' A random identifier per install, which Plex shows in its device list.
function NxPlexClientId() as String
    ' A dry run of the sign-in (MediaBrowserSignInTask) sets one for its own
    ' thread, so it neither saves an id nor shares the app's.
    dry = GetGlobalAA().nxDryRunClientId
    if NxIsString(dry) then
        if dry <> "" then return dry
    end if
    reg = NxPlexRegistry()
    id = reg.Read("clientId")
    if id = "" then
        id = CreateObject("roDeviceInfo").GetRandomUUID()
        reg.Write("clientId", id)
        reg.Flush()
    end if
    return id
end function

' One playback-session identifier per install and decoding profile, sent
' with every stream. Plex ties a device's streams together by it: a new one
' per stream made it refuse (HTTP 400) to restart a file for minutes after
' stopping it, which broke flipping back to a channel. Plex also fixes its
' transcode decision for a session the first time it sees it, so a change of
' profile (say, HEVC allowed) needs its own identifier.
function NxPlexPlaybackSessionId(profile as String) as String
    reg = NxPlexRegistry()
    key = "playbackSession_" + profile
    id = reg.Read(key)
    if id = "" then
        id = CreateObject("roDeviceInfo").GetRandomUUID()
        reg.Write(key, id)
        reg.Flush()
    end if
    return id
end function

function NxPlexLoadToken() as String
    return NxPlexRegistry().Read("token")
end function

sub NxPlexSaveToken(token as String)
    reg = NxPlexRegistry()
    reg.Write("token", token)
    reg.Flush()
end sub

' Sign out: forget the token, the chosen servers, and the device identifier.
sub NxPlexClearAuth()
    reg = NxPlexRegistry()
    for each key in reg.GetKeyList()
        reg.Delete(key)
    end for
    reg.Flush()
end sub

' ── HTTPS ───────────────────────────────────────────────────────────────────

function NxPlexHeaders(token as String) as Object
    h = {
        "Accept": "application/json",
        "X-Plex-Product": "nostalgex-roku",
        "X-Plex-Version": "0.1",
        "X-Plex-Platform": "Roku",
        "X-Plex-Device": "Roku",
        "X-Plex-Client-Identifier": NxPlexClientId()
    }
    if token <> "" then h["X-Plex-Token"] = token
    return h
end function

' One HTTPS request. Returns { code, json } where code is the HTTP status, or
' a negative curl code (-28 is a timeout), or 0 if the URL was refused. With
' plex set, the answer is repaired first (NxPlexUtf8Repair).
function NxHttp(method as String, url as String, headers as Object, timeoutMs = 10000 as Integer, plex = false as Boolean, body = "" as String) as Object
    if LCase(Left(url, 8)) <> "https://" then
        print "nxhttp: refused a non-HTTPS URL"
        return { code: 0, json: invalid }
    end if
    port = CreateObject("roMessagePort")
    xfer = CreateObject("roUrlTransfer")
    xfer.SetMessagePort(port)
    xfer.SetUrl(url)
    xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
    xfer.EnablePeerVerification(true)
    xfer.EnableHostVerification(true)
    xfer.RetainBodyOnError(true)
    xfer.SetHeaders(headers)
    xfer.SetRequest(method)
    if method = "POST" then
        ok = xfer.AsyncPostFromString(body)
    else
        ok = xfer.AsyncGetToString()
    end if
    if not ok then return { code: -1, json: invalid }
    msg = Wait(timeoutMs, port)
    if type(msg) <> "roUrlEvent" then
        xfer.AsyncCancel()
        return { code: -28, json: invalid }
    end if
    code = msg.GetResponseCode()
    if code < 200 or code > 299 then print "nxhttp: "; method; " answered "; code; " "; msg.GetFailureReason()
    body = msg.GetString()
    json = invalid
    if plex then body = NxPlexRepaired(body, url)
    if body <> "" then json = ParseJson(body)
    return { code: code, json: json }
end function

' A GET to a Plex server: HTTPS via NxHttp, or plain HTTP only when the host
' is private (the home-network address sign-in found). Anything else is
' refused. Returns { code, json } like NxHttp; code 0 if refused.
function NxPlexServerGet(url as String, token as String, timeoutMs = 15000 as Integer) as Object
    return NxServerRequest("GET", url, NxPlexHeaders(token), "", timeoutMs, true)
end function

' Several GETs to one Plex server, up to `width` in flight at once, under the
' same rules as NxPlexServerGet. Returns { code, json } per URL, in order.
function NxPlexServerGetMany(urls as Object, token as String, width as Integer, timeoutMs = 15000 as Integer) as Object
    return NxServerGetMany(urls, NxPlexHeaders(token), width, timeoutMs, true)
end function

' One request to a media server (Plex, Jellyfin or Emby): HTTPS with
' verification, or plain HTTP only when the host is private. Anything else is
' refused. A POST sends `body`. Returns { code, json } like NxHttp; code 0 if
' refused. With plex set, the answer is repaired first (NxPlexUtf8Repair).
function NxServerRequest(method as String, url as String, headers as Object, body = "" as String, timeoutMs = 15000 as Integer, plex = false as Boolean) as Object
    xfer = NxServerTransfer(url, headers)
    if xfer = invalid then return { code: 0, json: invalid }
    port = CreateObject("roMessagePort")
    xfer.SetMessagePort(port)
    xfer.SetRequest(method)
    if method = "GET" then
        ok = xfer.AsyncGetToString()
    else
        ok = xfer.AsyncPostFromString(body)
    end if
    if not ok then return { code: -1, json: invalid }
    msg = NxServerWait(timeoutMs, port)
    if type(msg) <> "roUrlEvent" then
        xfer.AsyncCancel()
        return { code: -28, json: invalid }
    end if
    text = msg.GetString()
    if plex then text = NxPlexRepaired(text, url)
    return { code: msg.GetResponseCode(), json: NxParseJsonBody(text) }
end function

' Several GETs to one server, up to `width` in flight at once, under the
' same rules as NxServerRequest. Returns { code, json } per URL, in order.
function NxServerGetMany(urls as Object, headers as Object, width as Integer, timeoutMs = 15000 as Integer, plex = false as Boolean) as Object
    out = []
    for i = 1 to urls.Count()
        out.Push({ code: -1, json: invalid })
    end for
    port = CreateObject("roMessagePort")
    live = {}
    nextIdx = 0
    pending = 0
    while nextIdx < urls.Count() or pending > 0
        ' A scan told to stop waiting starts nothing more; what's left
        ' answers -1.
        if NxLoadStopped() then
            for each id in live
                live[id].xfer.AsyncCancel()
            end for
            exit while
        end if
        while pending < width and nextIdx < urls.Count()
            xfer = NxServerTransfer(urls[nextIdx], headers)
            if xfer = invalid then
                out[nextIdx] = { code: 0, json: invalid }
            else
                xfer.SetMessagePort(port)
                if xfer.AsyncGetToString() then
                    live[xfer.GetIdentity().ToStr()] = { xfer: xfer, index: nextIdx }
                    pending = pending + 1
                end if
            end if
            nextIdx = nextIdx + 1
        end while
        if pending = 0 then exit while
        msg = NxServerWait(timeoutMs, port)
        if type(msg) = "roUrlEvent" then
            id = msg.GetSourceIdentity().ToStr()
            job = live[id]
            if job <> invalid then
                live.Delete(id)
                pending = pending - 1
                text = msg.GetString()
                if plex then text = NxPlexRepaired(text, urls[job.index])
                out[job.index] = { code: msg.GetResponseCode(), json: NxParseJsonBody(text) }
            end if
        else if msg = invalid then
            ' Nothing answered in time: what's still out timed out.
            for each id in live
                live[id].xfer.AsyncCancel()
                out[live[id].index] = { code: -28, json: invalid }
            end for
            live.Clear()
            pending = 0
        end if
    end while
    return out
end function

' A server's answer on `port`, as Wait(timeoutMs, port), while a library
' scan runs under the loading screen's stall watch (LibraryTask's
' stopWaiting): every answer that came back 2xx counts as progress there
' (scanAnswers), and a stop ends the wait within a quarter second, as a
' timeout. Outside a scan, a plain Wait.
function NxServerWait(timeoutMs as Integer, port as Object) as Dynamic
    watch = m.nxLoadWatch
    if watch = invalid then return Wait(timeoutMs, port)
    clock = CreateObject("roTimespan")
    while not NxLoadStopped()
        left = timeoutMs - clock.TotalMilliseconds()
        if left <= 0 then return invalid
        if left > 250 then left = 250
        msg = Wait(left, port)
        if type(msg) = "roUrlEvent" then
            code = msg.GetResponseCode()
            if code >= 200 and code <= 299 then watch.scanAnswers = watch.scanAnswers + 1
            return msg
        end if
    end while
    return invalid
end function

' True once the library scan running was told to stop waiting: no more
' requests or tries for it.
function NxLoadStopped() as Boolean
    watch = m.nxLoadWatch
    return watch <> invalid and watch.stopWaiting <> ""
end function

' A Plex answer as text a JSON parser reads, as upstream's PlexUTF8Repair
' (Services/PlexResponseDecoding.swift) and the web tuner's
' scripts/nostalgex-utf8-repair.js. Plex copies a file or folder name into
' its JSON byte for byte, so a name written in Latin-1 puts a byte there that
' isn't UTF-8. The Roku keeps that byte, and a label draws it as a box that
' swallows the letters after it ("Caf" and a box, then "ociety", issue
' #121). One line in the log when anything was repaired, as upstream's.
function NxPlexRepaired(text as String, url as String) as String
    fixed = NxPlexUtf8Repair(text)
    if fixed.repairedBytes > 0 then print "PLEX UTF-8 "; NxUrlPathAndQuery(url); ": repaired "; fixed.repairedBytes; " byte(s) that were not UTF-8, read as Windows-1252"
    return fixed.text
end function

' A URL's path and query, as upstream's logContext. The port sends the token
' in a header, never in a URL.
function NxUrlPathAndQuery(url as String) as String
    i = Instr(1, url, "://")
    if i = 0 then return url
    j = Instr(i + 3, url, "/")
    if j = 0 then return "/"
    return Mid(url, j)
end function

' { text, repairedBytes }: valid UTF-8 comes back as it is, less one leading
' byte order mark (a JSON decoder ignores it; ParseJson fails on it). Else
' every byte outside a well-formed UTF-8 sequence is read as Windows-1252.
function NxPlexUtf8Repair(text as String) as Object
    ' roRegex is UTF-8 and matches nothing in a string that isn't, so the
    ' empty pattern is the check: 7 ms a megabyte on a TV, where a byte loop
    ' takes 570. It agrees with every case in the golden vectors.
    valid = CreateObject("roRegex", "^", "")
    if valid.IsMatch(text) then
        if Left(text, 1) = Chr(65279) then text = Mid(text, 2)
        return { text: text, repairedBytes: 0 }
    end if
    ' The byte loop took 3.8 s on a 1 MB page with one bad title, so only
    ' the items that fail the check go through it. A page splits between
    ' its items at "},{", ASCII that no UTF-8 sequence spans, and joins back
    ' byte for byte.
    parts = text.Split("},{")
    repaired = 0
    for i = 0 to parts.Count() - 1
        if not valid.IsMatch(parts[i]) then
            bytes = CreateObject("roByteArray")
            bytes.FromAsciiString(parts[i])
            fixed = NxUtf8RepairBytes(bytes, i = 0)
            parts[i] = fixed.text
            repaired = repaired + fixed.repairedBytes
        else if i = 0 and Left(parts[0], 1) = Chr(65279) then
            parts[0] = Mid(parts[0], 2)
        end if
    end for
    return { text: parts.Join("},{"), repairedBytes: repaired }
end function

' The repair itself, over bytes, as PlexUTF8Repair.repair: well-formed
' sequences are copied, each other byte becomes its Windows-1252 character.
' With leading set, one leading byte order mark is dropped. { text,
' repairedBytes }.
function NxUtf8RepairBytes(b as Object, leading = true as Boolean) as Object
    n = b.Count()
    out = CreateObject("roByteArray")
    i = 0
    if leading and n >= 3 then
        if b[0] = &hEF and b[1] = &hBB and b[2] = &hBF then i = 3
    end if
    repaired = 0
    while i < n
        k = NxUtf8SequenceLength(b, i, n)
        if k > 0 then
            for j = i to i + k - 1
                out.Push(b[j])
            end for
            i = i + k
        else
            cp = NxWindows1252(b[i])
            if cp < &h800 then
                out.Push(&hC0 or (cp >> 6))
                out.Push(&h80 or (cp and &h3F))
            else
                out.Push(&hE0 or (cp >> 12))
                out.Push(&h80 or ((cp >> 6) and &h3F))
                out.Push(&h80 or (cp and &h3F))
            end if
            repaired = repaired + 1
            i = i + 1
        end if
    end while
    return { text: out.ToAsciiString(), repairedBytes: repaired }
end function

' Length of the well-formed UTF-8 sequence at i (Unicode table 3-7), or 0,
' as upstream's sequenceLength.
function NxUtf8SequenceLength(b as Object, i as Integer, n as Integer) as Integer
    b0 = b[i]
    if b0 < &h80 then return 1
    if b0 >= &hC2 and b0 <= &hDF then
        if NxUtf8Cont(b, i + 1, n, &h80, &hBF) then return 2
    else if b0 = &hE0 then
        if NxUtf8Cont(b, i + 1, n, &hA0, &hBF) and NxUtf8Cont(b, i + 2, n, &h80, &hBF) then return 3
    else if (b0 >= &hE1 and b0 <= &hEC) or b0 = &hEE or b0 = &hEF then
        if NxUtf8Cont(b, i + 1, n, &h80, &hBF) and NxUtf8Cont(b, i + 2, n, &h80, &hBF) then return 3
    else if b0 = &hED then
        if NxUtf8Cont(b, i + 1, n, &h80, &h9F) and NxUtf8Cont(b, i + 2, n, &h80, &hBF) then return 3
    else if b0 = &hF0 then
        if NxUtf8Cont(b, i + 1, n, &h90, &hBF) and NxUtf8Cont(b, i + 2, n, &h80, &hBF) and NxUtf8Cont(b, i + 3, n, &h80, &hBF) then return 4
    else if b0 >= &hF1 and b0 <= &hF3 then
        if NxUtf8Cont(b, i + 1, n, &h80, &hBF) and NxUtf8Cont(b, i + 2, n, &h80, &hBF) and NxUtf8Cont(b, i + 3, n, &h80, &hBF) then return 4
    else if b0 = &hF4 then
        if NxUtf8Cont(b, i + 1, n, &h80, &h8F) and NxUtf8Cont(b, i + 2, n, &h80, &hBF) and NxUtf8Cont(b, i + 3, n, &h80, &hBF) then return 4
    end if
    return 0
end function

function NxUtf8Cont(b as Object, k as Integer, n as Integer, low as Integer, high as Integer) as Boolean
    if k >= n then return false
    return b[k] >= low and b[k] <= high
end function

' A byte as Windows-1252: 0x80 to 0x9F hold the curly quotes, dashes, the
' euro sign and the rest; 0xA0 to 0xFF match Latin-1. The five bytes
' Windows-1252 leaves undefined keep their Latin-1 code point, as browsers do.
function NxWindows1252(value as Integer) as Integer
    if value < &h80 or value > &h9F then return value
    high = [&h20AC, &h0081, &h201A, &h0192, &h201E, &h2026, &h2020, &h2021, &h02C6, &h2030, &h0160, &h2039, &h0152, &h008D, &h017D, &h008F, &h0090, &h2018, &h2019, &h201C, &h201D, &h2022, &h2013, &h2014, &h02DC, &h2122, &h0161, &h203A, &h0153, &h009D, &h017E, &h0178]
    return high[value - &h80]
end function

' A response body as JSON, or invalid. Only a body that starts as JSON is
' parsed: an error page or plain text ("Access token is invalid or expired.")
' would put a ParseJSON error in the log.
function NxParseJsonBody(text as String) as Dynamic
    t = text.Trim()
    if t = "" then return invalid
    first = Left(t, 1)
    if first <> "{" and first <> "[" then return invalid
    return ParseJson(t)
end function

' A transfer for one server request, or invalid when the URL is refused:
' HTTPS with verification, or plain HTTP to a home-network address only.
function NxServerTransfer(url as String, headers as Object) as Dynamic
    if not NxServerUrlAllowed(url) then
        print "nxhttp: refused plain HTTP to a non-private address"
        return invalid
    end if
    xfer = CreateObject("roUrlTransfer")
    if LCase(Left(url, 8)) = "https://" then
        xfer.SetCertificatesFile("common:/certs/ca-bundle.crt")
        xfer.EnablePeerVerification(true)
        xfer.EnableHostVerification(true)
    end if
    xfer.RetainBodyOnError(true)
    xfer.SetUrl(url)
    xfer.SetHeaders(headers)
    return xfer
end function

' HTTPS anywhere, plain HTTP to a home-network host only (NxIsPrivateHost).
function NxServerUrlAllowed(url as String) as Boolean
    lower = LCase(url)
    if Left(lower, 8) = "https://" then return true
    return Left(lower, 7) = "http://" and NxIsPrivateHost(NxUrlHost(url))
end function

' A transfer for one Plex GET, or invalid when the URL is refused.
function NxPlexTransfer(url as String, token as String) as Dynamic
    return NxServerTransfer(url, NxPlexHeaders(token))
end function

function NxPlexVideoRequest(url as String, token as String, timeoutMs = 5000 as Integer) as Integer
    return NxPlexServerGet(url, token, timeoutMs).code
end function

' Percent-encodes all but A-Z a-z 0-9 - _ . ~, byte by byte in UTF-8, as
' roUrlTransfer.Escape does. That component is task-only on Roku OS 16, and
' this runs on the render thread, where creating it crashed the app.
function NxUrlEncode(s as String) as String
    bytes = CreateObject("roByteArray")
    bytes.FromAsciiString(s)
    hex = "0123456789ABCDEF"
    out = ""
    for each b in bytes
        if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or b = 45 or b = 95 or b = 46 or b = 126 then
            out = out + Chr(b)
        else
            out = out + "%" + Mid(hex, (b >> 4) + 1, 1) + Mid(hex, (b and 15) + 1, 1)
        end if
    end for
    return out
end function

' The host a request to url goes to. Anything before an "@" is user info,
' not the host: `http://10.0.0.1:80@example.com/` goes to example.com.
function NxUrlHost(url as String) as String
    rest = Mid(url, Instr(1, url, "//") + 2)
    cut = Instr(1, rest, "/")
    if cut > 0 then rest = Left(rest, cut - 1)
    for each ch in ["?", "#"]
        cut = Instr(1, rest, ch)
        if cut > 0 then rest = Left(rest, cut - 1)
    end for
    at = 0
    for i = Len(rest) to 1 step -1
        if Mid(rest, i, 1) = "@" then
            at = i
            exit for
        end if
    end for
    if at > 0 then rest = Mid(rest, at + 1)
    colon = Instr(1, rest, ":")
    if colon > 0 then rest = Left(rest, colon - 1)
    return rest
end function

' ── plex.tv ─────────────────────────────────────────────────────────────────

' A new link PIN: { id, code } or invalid.
' A new plex.tv/link PIN as { id, code }, or invalid. out, when given, gets
' the request's code (an HTTP status, or curl's when nothing answered).
function NxPlexCreatePin(out = invalid as Dynamic) as Dynamic
    res = NxHttp("POST", "https://plex.tv/api/v2/pins", NxPlexHeaders(""))
    if out <> invalid then out.code = res.code
    if res.code < 200 or res.code > 299 or type(res.json) <> "roAssociativeArray" then return invalid
    if res.json.id = invalid or res.json.code = invalid then return invalid
    return { id: res.json.id, code: UCase(res.json.code) }
end function

' The PIN's token once the user has entered the code at plex.tv/link: a
' String, "" while still waiting, or invalid when the PIN has expired.
function NxPlexCheckPin(id as Dynamic) as Dynamic
    res = NxHttp("GET", "https://plex.tv/api/v2/pins/" + NxToStr(id), NxPlexHeaders(""))
    if res.code = 404 then return invalid
    if type(res.json) <> "roAssociativeArray" then return ""
    if NxIsString(res.json.authToken) then return res.json.authToken
    return ""
end function

' The signed-in account as { name, id }, "" if the token was rejected, or
' invalid if plex.tv couldn't be reached (so a network blip doesn't sign
' anyone out). id is the account's uuid, or its number when there is none.
function NxPlexAccount(token as String) as Dynamic
    res = NxHttp("GET", "https://plex.tv/api/v2/user", NxPlexHeaders(token))
    if res.code = 401 or res.code = 403 then return ""
    if res.code < 200 or res.code > 299 or type(res.json) <> "roAssociativeArray" then return invalid
    name = res.json.username
    if not NxIsString(name) or name = "" then name = res.json.title
    if not NxIsString(name) then name = "Plex"
    id = NxToStr(res.json.uuid)
    if id = "" then id = NxToStr(res.json.id)
    return { name: name, id: id }
end function

' Servers on the account: [{ name, machineIdentifier, owned, accessToken,
' connections }], or invalid if plex.tv couldn't be reached.
function NxPlexServers(token as String) as Dynamic
    res = NxHttp("GET", "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1", NxPlexHeaders(token), 15000, true)
    if res.code < 200 or res.code > 299 or type(res.json) <> "roArray" then return invalid
    out = []
    for each r in res.json
        if type(r) = "roAssociativeArray" and NxIsString(r.provides) then
            if Instr(1, r.provides, "server") > 0 then
                out.Push({
                    name: NxToStr(r.name),
                    machineIdentifier: NxToStr(r.clientIdentifier),
                    owned: NxTruthy(r.owned),
                    accessToken: NxToStr(r.accessToken),
                    connections: NxList(r.connections)
                })
            end if
        end if
    end for
    return out
end function

' Plex's answer to POST /users/sign_in.json, read into { status, token,
' name }: "ok" with the token and the account name (from whichever of the
' response's fields carries them: the field name has drifted between Plex
' API versions, and this is the legacy JSON endpoint), "invalid" (401: a
' wrong password, a wrong two-factor code, or an account that signs in
' through Google or Apple and so has no Plex password at all, which the
' Roku can't tell apart from a wrong password) or "error" (anything else,
' including no connection, or a 2xx with no token in it). Pure, so this is
' where tests/SignInFlowTests.brs holds the parsing to cases; only status,
' token and name ever leave it, nothing else the response carried.
function NxPlexPasswordAuthResult(code as Integer, json as Dynamic) as Object
    if code = 401 then return { status: "invalid", token: "", name: "" }
    if code >= 200 and code <= 299 then
        auth = invalid
        if type(json) = "roAssociativeArray" then
            if type(json.user) = "roAssociativeArray" then auth = json.user else auth = json
        end if
        if type(auth) = "roAssociativeArray" then
            token = ""
            if NxIsString(auth.authToken) then token = auth.authToken
            if token = "" and NxIsString(auth.authenticationToken) then token = auth.authenticationToken
            if token <> "" then
                name = auth.username
                if not NxIsString(name) or name = "" then name = auth.title
                if not NxIsString(name) or name = "" then name = "Plex"
                return { status: "ok", token: token, name: name }
            end if
        end if
    end if
    return { status: "error", token: "", name: "" }
end function

' Email and password sign-in direct to plex.tv (POST /users/sign_in.json),
' the on-device path Roku certification rule 2.2 requires alongside the
' plex.tv/link code (NxPlexCreatePin / NxPlexCheckPin): Plex's own Roku app
' dropped a link-code-only sign-in at version 7.6.0/7.6.1 over this same
' rule. A two-factor code, when the account has one on, goes on the end of
' the password with no separator, Plex's own documented way for an app with
' no separate code field; nothing here needs to know that. The password is
' sent once and never kept: this function returns only what
' NxPlexPasswordAuthResult reads out of the answer, and the caller
' (PlexSignInTask) saves only the token (NxPlexSaveToken), the same as the
' link code's token.
function NxPlexSignInWithPassword(login as String, password as String) as Object
    headers = NxPlexHeaders("")
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    body = "user%5Blogin%5D=" + NxUrlEncode(login) + "&user%5Bpassword%5D=" + NxUrlEncode(password)
    res = NxHttp("POST", "https://plex.tv/users/sign_in.json", headers, 15000, true, body)
    return NxPlexPasswordAuthResult(res.code, res.json)
end function

' True for a host on the home network, the only place plain HTTP may go
' (Discussion #8, phase 1 item 3; upstream allows plain http anywhere):
'   - RFC 1918 IPv4 addresses (10/8, 172.16/12, 192.168/16) and Tailscale's
'     100.64.0.0/10;
'   - names ending .local, .lan, .home.arpa or .ts.net (Tailscale's MagicDNS);
'   - single-label names such as `nas`, which only a home resolver answers.
' The examples on screen use a single word: on a 43S45 (OS 16.0.4) a server's
' one-word name, answered by the router's DNS, worked, while the same
' server's .local name, announced by mDNS, got no answer, so a Roku looks
' like it doesn't resolve .local (2026-10-21).
' A name that is all digits, or hex, is refused: curl and inet_aton read
' `134744072` and `0x8080808` as 8.8.8.8. So is an octet with a leading zero,
' which they read as octal (`010.0.0.1` is 8.0.0.1). Unchecked on a TV, so
' refused rather than trusted.
function NxIsPrivateHost(host as String) as Boolean
    h = LCase(host)
    if Right(h, 1) = "." then h = Left(h, Len(h) - 1)
    if CreateObject("roRegex", "^\d+(\.\d+)*$", "").IsMatch(h) then
        parts = h.Split(".")
        if parts.Count() <> 4 then return false
        for each p in parts
            if not CreateObject("roRegex", "^(0|[1-9]\d{0,2})$", "").IsMatch(p) then return false
        end for
        a = parts[0].ToInt()
        b = parts[1].ToInt()
        if a = 10 then return true
        if a = 192 and b = 168 then return true
        if a = 172 and b >= 16 and b <= 31 then return true
        if a = 100 and b >= 64 and b <= 127 then return true
        return false
    end if
    if not CreateObject("roRegex", "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$", "").IsMatch(h) then return false
    if Instr(1, h, ".") = 0 then return not CreateObject("roRegex", "^0x[0-9a-f]+$", "").IsMatch(h)
    for each suffix in [".local", ".lan", ".home.arpa", ".ts.net"]
        if Len(h) > Len(suffix) and Right(h, Len(suffix)) = suffix then return true
    end for
    return false
end function
