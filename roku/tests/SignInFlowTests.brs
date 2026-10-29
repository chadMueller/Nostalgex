' Runs source/mediabrowser/SignInFlow.brs and NxMbDiscoveryReply: the
' decisions behind the connect screens, held to upstream's
' NostalgexTests/SignInFlowTests.swift case by case (what discovery leads to,
' which way in a server gets first, what the address check reads before
' anyone types), plus the port's own: the reply parser, the curl-code
' messages, Quick Connect polling and where focus starts. Fields are compared
' one by one: FormatJson of an AA literal lowercases its keys on a TV.
' Returns the failure count.

function NxRunSignInFlowTests() as Integer
    r = { pass: 0, fail: 0 }

    ' ── Discovery outcome ──
    a = NxSignInTestServer("a", "http://192.168.1.10:8096")
    b = NxSignInTestServer("b", "http://192.168.1.11:8096")
    out = NxSignInOutcome([a])
    NxCheck(r, "one server answering goes straight to it", out.kind + " " + NxSignInTestIds(out.servers), "single a")
    wifi = NxSignInTestServer("a", "http://192.0.2.45:8096")
    ethernet = NxSignInTestServer("a", "http://192.0.2.49:8096")
    out = NxSignInOutcome([wifi, ethernet])
    NxCheck(r, "the same server twice is still one", out.kind + " " + out.servers[0].address, "single http://192.0.2.45:8096")
    out = NxSignInOutcome([a, b])
    NxCheck(r, "two servers are listed", out.kind + " " + NxSignInTestIds(out.servers), "several a,b")
    NxCheck(r, "nothing answering offers the typed address", NxSignInOutcome([]).kind, "none")
    NxCheck(r, "stand-in only when asked", NxToStr(NxSignInDiscoveryFixture("") = invalid), "true")
    NxCheck(r, "stand-in none", NxSignInDiscoveryFixture("none").Count().ToStr(), "0")
    several = NxSignInDiscoveryFixture("several")
    NxCheck(r, "stand-in several is a pick", several.Count().ToStr() + " " + NxSignInOutcome(several).kind, "2 several")

    ' ── The reply to the broadcast (LANServerDiscovery.parseReply) ──
    reply = NxMbDiscoveryReply("{""Address"":"" http://192.0.2.79:8096 "",""Id"":""a7c1"",""Name"":""Den Server""}")
    NxCheck(r, "reply read", reply.name + " " + reply.address + " " + reply.id, "Den Server http://192.0.2.79:8096 a7c1")
    reply = NxMbDiscoveryReply("{""Address"":""http://10.0.0.2:8096"",""Id"":""x"",""Name"":""""}")
    NxCheck(r, "reply with no name is named by its address", reply.name, "http://10.0.0.2:8096")
    NxCheck(r, "reply with no Id is not a server", NxToStr(NxMbDiscoveryReply("{""Address"":""http://10.0.0.2:8096""}") = invalid), "true")
    NxCheck(r, "reply that isn't JSON", NxToStr(NxMbDiscoveryReply("who is JellyfinServer?") = invalid), "true")

    ' ── Which way in ──
    NxCheck(r, "Quick Connect when Jellyfin says it is on", NxSignInPreferredMethod("jellyfin", true), "quickConnect")
    NxCheck(r, "password when Jellyfin says off", NxSignInPreferredMethod("jellyfin", false), "password")
    NxCheck(r, "password when Jellyfin can't say", NxSignInPreferredMethod("jellyfin", invalid), "password")
    for each answer in [true, false, invalid]
        label = "Emby with " + FormatJson(answer)
        NxCheck(r, label + ": password", NxSignInPreferredMethod("emby", answer), "password")
        NxCheck(r, label + ": no Quick Connect", NxToStr(NxSignInOffersQuickConnect("emby", answer)), "false")
    end for
    NxCheck(r, "Quick Connect offered when on", NxToStr(NxSignInOffersQuickConnect("jellyfin", true)), "true")
    NxCheck(r, "Quick Connect offered when it can't say", NxToStr(NxSignInOffersQuickConnect("jellyfin", invalid)), "true")
    NxCheck(r, "Quick Connect hidden only when off", NxToStr(NxSignInOffersQuickConnect("jellyfin", false)), "false")

    ' ── Parsing ──
    NxCheck(r, "enabled true", FormatJson(NxSignInQuickConnectEnabled(200, "true")), "true")
    NxCheck(r, "enabled false", FormatJson(NxSignInQuickConnectEnabled(200, " false" + Chr(10))), "false")
    NxCheck(r, "enabled 404 (Emby 4.10)", FormatJson(NxSignInQuickConnectEnabled(404, "The file '/QuickConnect/Enabled' could not be found.")), "null")
    NxCheck(r, "enabled web page", FormatJson(NxSignInQuickConnectEnabled(200, "<html></html>")), "null")
    ' Shaped as Jellyfin 12.2.0 and Emby 4.10.1.0 answer, with made-up names and Ids.
    jf = NxSignInPublicInfo(ParseJson("{""LocalAddress"":""http://127.0.0.1:8096"",""ServerName"":""Living Room"",""Version"":""12.2.0"",""ProductName"":""Jellyfin Server"",""OperatingSystem"":"""",""Id"":""0f1e2d3c"",""StartupWizardCompleted"":true}"))
    NxCheck(r, "public info Jellyfin", jf.id + " " + jf.name + " " + jf.kind, "0f1e2d3c Living Room jellyfin")
    em = NxSignInPublicInfo(ParseJson("{""LocalAddresses"":[],""RemoteAddresses"":[],""ServerName"":""Den Server"",""Version"":""4.10.1.0"",""Id"":""9a8b7c6d""}"))
    NxCheck(r, "public info Emby", em.id + " " + em.name + " " + em.kind, "9a8b7c6d Den Server emby")
    NxCheck(r, "no Id is not a server", NxToStr(NxSignInPublicInfo(ParseJson("{""ServerName"":""router""}")) = invalid), "true")
    NxCheck(r, "a web page is not a server", NxToStr(NxSignInPublicInfo(NxParseJsonBody("<!doctype html>")) = invalid), "true")
    users = NxSignInPublicUsers(ParseJson("[{""Name"":""avsync"",""Id"":""u1"",""HasPassword"":true},{""Name"":""kids"",""Id"":""u2"",""HasPassword"":false},{""Name"":"""",""Id"":""u3""},{""Name"":""no id""}]"))
    NxCheck(r, "public users", NxSignInTestUsers(users), "u1 avsync true|u2 kids false")
    NxCheck(r, "public users none", NxSignInPublicUsers(ParseJson("[]")).Count().ToStr(), "0")
    NxCheck(r, "public users not JSON", NxSignInPublicUsers(NxParseJsonBody("nope")).Count().ToStr(), "0")
    users = NxSignInPublicUsers(ParseJson("[{""Name"":""old"",""Id"":""u9""}]"))
    NxCheck(r, "no HasPassword means a password", NxSignInTestUsers(users), "u9 old true")

    ' ── The address check ──
    jellyfinInfo = "{""ServerName"":""Living Room"",""ProductName"":""Jellyfin Server"",""Id"":""jf1""}"
    embyInfo = "{""ServerName"":""Den"",""Id"":""em1""}"

    fake = NxSignInFake({
        "http://192.168.1.10:8096/System/Info/Public": { code: 200, text: jellyfinInfo },
        "http://192.168.1.10:8096/QuickConnect/Enabled": { code: 200, text: "true" },
        "http://192.168.1.10:8096/Users/Public": { code: 200, text: "[]" }
    }, [])
    got = NxSignInCheck("192.168.1.10", fake)
    s = got.server
    NxCheck(r, "bare address finds Jellyfin on 8096", s.kind + " " + s.url + " " + s.name + " " + FormatJson(s.quickConnect) + " " + s.users.Count().ToStr(), "jellyfin http://192.168.1.10:8096 Living Room true 0")
    NxCheck(r, "and opens on Quick Connect", NxSignInPreferredMethod(s.kind, s.quickConnect), "quickConnect")

    fake = NxSignInFake({
        "http://jf.local:8096/System/Info/Public": { code: 200, text: jellyfinInfo },
        "http://jf.local:8096/QuickConnect/Enabled": { code: 200, text: "false" }
    }, [])
    s = NxSignInCheck("http://jf.local:8096", fake).server
    NxCheck(r, "Quick Connect off opens on password", NxSignInPreferredMethod(s.kind, s.quickConnect) + " " + NxToStr(NxSignInOffersQuickConnect(s.kind, s.quickConnect)), "password false")

    fake = NxSignInFake({
        "http://192.168.1.20:8096/System/Info/Public": { code: 200, text: embyInfo },
        "http://192.168.1.20:8096/Users/Public": { code: 200, text: "[{""Name"":""dad"",""Id"":""d"",""HasPassword"":false}]" }
    }, [])
    s = NxSignInCheck("http://192.168.1.20:8096", fake).server
    NxCheck(r, "Emby shows its users", s.kind + " " + FormatJson(s.quickConnect) + " " + NxSignInTestUsers(s.users), "emby null d dad false")
    askedQC = false
    for each u in fake.asked
        if Instr(1, u, "QuickConnect") > 0 then askedQC = true
    end for
    NxCheck(r, "Emby is never asked about Quick Connect", NxToStr(askedQC), "false")

    fake = NxSignInFake({ "http://10.0.0.5/System/Info/Public": { code: 200, text: embyInfo } }, ["http://10.0.0.5:8096"])
    NxCheck(r, "nothing on 8096 tries the address as typed", NxSignInCheck("10.0.0.5", fake).server.url, "http://10.0.0.5")

    fake = NxSignInFake({
        "http://192.168.1.1:8096/System/Info/Public": { code: 200, text: "<html>router</html>" },
        "http://192.168.1.1/System/Info/Public": { code: 200, text: "<html>router</html>" }
    }, [])
    NxCheck(r, "a web page is not a server", NxSignInCheck("192.168.1.1", fake).reason, "notAServer")

    fake = NxSignInFake({}, ["http://192.168.1.99"])
    got = NxSignInCheck("192.168.1.99", fake)
    NxCheck(r, "a refused connection is the network's answer", got.reason + " " + got.code.ToStr(), "unreachable -7")
    NxCheck(r, "and says nothing answered", NxToStr(Instr(1, NxSignInCheckMessage(got.reason, got.code, "emby"), "Nothing answered") = 1), "true")

    fake = NxSignInFake({
        "http://192.168.1.10:8096/System/Info/Public": { code: 200, text: jellyfinInfo },
        "http://192.168.1.10:8096/QuickConnect/Enabled": { code: 200, text: "true" }
    }, [])
    s = NxSignInCheck("192.168.1.10:8096", fake).server
    NxCheck(r, "the server says which kind it is", s.kind + " " + NxSignInPreferredMethod(s.kind, s.quickConnect), "jellyfin quickConnect")

    ' The port's own: NxServerTransfer refusing plain HTTP to a public
    ' address answers code 0; a timeout is the network's answer at once.
    fake = NxSignInFake({}, [])
    fake.zero = true
    NxCheck(r, "plain HTTP off the home network is refused", NxSignInCheck("http://203.0.113.5:8096", fake).reason, "refused")
    fake = NxSignInFake({}, [])
    fake.timeout = "http://10.0.0.7:8096"
    got = NxSignInCheck("10.0.0.7", fake)
    NxCheck(r, "a timeout stops the check", got.reason + " " + got.code.ToStr() + " " + fake.asked.Count().ToStr(), "unreachable -28 1")
    NxCheck(r, "not an address", NxSignInCheck("   ", NxSignInFake({}, [])).reason, "notAServer")

    ' The whole check stops at 12 s, each request at 8 s (the spec).
    fake = NxSignInFake({
        "http://192.0.2.5/System/Info/Public": { code: 200, text: embyInfo },
        "http://192.0.2.5/Users/Public": { code: 200, text: "[{""Name"":""dad"",""Id"":""d"",""HasPassword"":false}]" }
    }, ["http://192.0.2.5:8096"])
    fake.delays = { "http://192.0.2.5:8096": 7000, "http://192.0.2.5/System": 4000, "http://192.0.2.5/Users": 2000 }
    got = NxSignInCheck("192.0.2.5", fake)
    NxCheck(r, "12 s: found at 11 s, no time left for the users", got.server.url + " " + got.server.users.Count().ToStr() + " " + fake.clock.ToStr(), "http://192.0.2.5 0 12000")
    fake = NxSignInFake({ "http://192.0.2.6/System/Info/Public": { code: 200, text: embyInfo } }, ["http://192.0.2.6:8096"])
    fake.delays = { "http://192.0.2.6:8096": 8000, "http://192.0.2.6/System": 5000 }
    got = NxSignInCheck("192.0.2.6", fake)
    NxCheck(r, "12 s: the second address runs out of time", got.reason + " " + got.code.ToStr() + " " + fake.clock.ToStr(), "unreachable -28 12000")
    fake = NxSignInFake({}, [])
    fake.delays = { "http://192.0.2.7:8096": 20000 }
    got = NxSignInCheck("http://192.0.2.7:8096", fake)
    NxCheck(r, "8 s: one request", got.reason + " " + got.code.ToStr() + " " + fake.clock.ToStr(), "unreachable -28 8000")
    ' A clock that moves on each reading: the check found the server at
    ' 11,999 ms, and reading the time left twice would hand Quick Connect's
    ' request 0 ms (Wait(0) waits forever on a Roku). Every request gets 1 ms
    ' or more.
    fake = NxSignInFake({
        "http://192.0.2.8/System/Info/Public": { code: 200, text: jellyfinInfo },
        "http://192.0.2.8/QuickConnect/Enabled": { code: 200, text: "true" }
    }, ["http://192.0.2.8:8096"])
    ' Readings at 0 and 8,000 ms (each moves the clock 1 ms), answers after
    ' 7,999 and 3,998: Quick Connect's time left is read at 11,999.
    fake.delays = { "http://192.0.2.8:8096": 7999, "http://192.0.2.8/System": 3998 }
    fake.tick = 1
    got = NxSignInCheck("192.0.2.8", fake)
    shortest = 99999
    for each t in fake.timeouts
        if t < shortest then shortest = t
    end for
    NxCheck(r, "no request gets 0 ms", NxToStr(shortest >= 1) + " " + got.server.kind + " " + FormatJson(got.server.quickConnect), "true jellyfin true")
    NxCheck(r, "Wait never gets 0", NxSignInWaitMs(0).ToStr() + " " + NxSignInWaitMs(-40).ToStr() + " " + NxSignInWaitMs(8000).ToStr(), "1 1 8000")

    ' ── Finishing a sign-in, and the tour's dry run ──
    saver = { calls: 0, save: NxSignInTestSave }
    NxCheck(r, "finish: saved for real", NxSignInFinish(false, { token: "t", userId: "u" }, saver) + " " + saver.calls.ToStr(), "signedIn 1")
    saver = { calls: 0, save: NxSignInTestSave }
    NxCheck(r, "finish: a dry run saves nothing", NxSignInFinish(true, { token: "t", userId: "u" }, saver) + " " + saver.calls.ToStr(), "signedIn 0")
    NxCheck(r, "finish: the dry run's stand-in", NxSignInFinish(true, NxSignInDryRunAuth(), saver) + " " + saver.calls.ToStr(), "signedIn 0")
    NxCheck(r, "finish: refused", NxSignInFinish(false, "", saver) + " " + saver.calls.ToStr(), "refused 0")
    NxCheck(r, "finish: not reached", NxSignInFinish(false, invalid, saver) + " " + saver.calls.ToStr(), "unreached 0")
    g = GetGlobalAA()
    g.nxDryRunClientId = "dry-run-test"
    NxCheck(r, "a dry run's install id is its own", NxPlexClientId(), "dry-run-test")
    ' On a TV, the dry run leaves the registry as it was, compared by a hash
    ' of every section, key and value (none is printed). A saver that would
    ' write if it were called stands in for the real one.
    if NxTestRuntime() = "device" then
        before = NxSignInRegistryDigest()
        tripwire = { calls: 0, save: NxSignInTripwireSave }
        NxSignInFinish(true, NxSignInDryRunAuth(), tripwire)
        NxPlexClientId()
        after = NxSignInRegistryDigest()
        if tripwire.calls > 0 then CreateObject("roRegistry").Delete("nxSignInTripwire")
        NxCheck(r, "a dry run never writes the registry", NxToStr(after = before) + " " + tripwire.calls.ToStr(), "true 0")
    else
        print "  skip the registry check: this interpreter has no registry"
    end if
    g.Delete("nxDryRunClientId")

    ' ── What the viewer reads ──
    NxCheck(r, "msg not a server", NxSignInCheckMessage("notAServer", 0, "jellyfin"), NxSignInCopy().notAServer)
    NxCheck(r, "msg host", NxSignInCheckMessage("unreachable", -6, "jellyfin"), "Could not find that host. Check the address.")
    localHint = "Could not find that host. A Roku can't look up .local names, so type the server's IP address."
    NxCheck(r, "msg host .local", NxSignInCheckMessage("unreachable", -6, "jellyfin", "nas.local"), localHint)
    NxCheck(r, "msg host .local with scheme and port", NxSignInCheckMessage("unreachable", -6, "emby", "http://NAS.Local.:8096/web"), localHint)
    NxCheck(r, "msg host one word", NxSignInCheckMessage("unreachable", -6, "jellyfin", "nas"), "Could not find that host. Check the address.")
    NxCheck(r, "msg host .localhost is not .local", NxSignInCheckMessage("unreachable", -6, "jellyfin", "nas.localhost"), "Could not find that host. Check the address.")
    NxCheck(r, "msg .local, other error", NxSignInCheckMessage("unreachable", -7, "jellyfin", "nas.local"), "Nothing answered at that address and port. Check the port (Jellyfin and Emby default to 8096).")
    NxCheck(r, "msg timeout", NxSignInCheckMessage("unreachable", -28, "emby"), "The Emby server took too long to answer. Check the address, or that the Roku can reach it.")
    NxCheck(r, "msg certificate", NxSignInCheckMessage("unreachable", -60, "jellyfin"), "The server's HTTPS certificate is not trusted by the Roku (error -60).")
    NxCheck(r, "msg other", NxSignInCheckMessage("unreachable", -3, "jellyfin"), "Could not reach the Jellyfin server (error -3). Check the address.")
    NxCheck(r, "msg no code (a sign-in answered, not 401)", NxSignInCheckMessage("unreachable", 0, "emby"), "Could not reach the Emby server. Check the address.")

    ' ── plex.tv, on the first screen (SIGNIN-FLOW.md, Errors) ──
    NxCheck(r, "plex 429", NxSignInPlexMessage(429), "plex.tv is rate-limiting sign-in requests from this device. Wait a minute, then press CONNECT TO PLEX again.")
    NxCheck(r, "plex offline", NxSignInPlexMessage(-6), "No internet connection. Check the Roku's Wi-Fi or Ethernet, then press CONNECT TO PLEX again.")
    NxCheck(r, "plex timeout", NxSignInPlexMessage(-28), "plex.tv took too long to respond. Check your connection, then press CONNECT TO PLEX again.")
    NxCheck(r, "plex other network error", NxSignInPlexMessage(-35), "Could not reach plex.tv (error -35). Check your connection, then press CONNECT TO PLEX again.")
    NxCheck(r, "plex HTTP error", NxSignInPlexMessage(503), "plex.tv returned an error (HTTP 503). Try again in a moment.")
    NxCheck(r, "plex no detail", NxSignInPlexMessage(0), "Could not reach plex.tv. Check your connection, then press CONNECT TO PLEX again.")
    NxCheck(r, "plex answered but no PIN", NxSignInPlexMessage(201), "Could not reach plex.tv. Check your connection, then press CONNECT TO PLEX again.")
    c = NxSignInCopy()
    NxCheck(r, "plex code expired", c.plexCodeExpired, "The code expired. Press CONNECT TO PLEX for a new one.")
    NxCheck(r, "Quick Connect code expired", c.codeExpired, "The code expired. Press USE QUICK CONNECT for a new one, or sign in with your password.")
    NxCheck(r, "msg refused", Left(NxSignInCheckMessage("refused", 0, "emby"), 40), "Nostalgex reaches a server over HTTPS, o")

    ' ── Quick Connect polling ──
    NxCheck(r, "approved", NxSignInQuickConnectStep(1, true), "approved")
    NxCheck(r, "not yet", NxSignInQuickConnectStep(1, false), "waiting")
    NxCheck(r, "a failed poll waits on", NxSignInQuickConnectStep(7, invalid), "waiting")
    NxCheck(r, "the last poll", NxSignInQuickConnectStep(150, true), "approved")
    NxCheck(r, "expired after 150", NxSignInQuickConnectStep(151, true), "expired")

    ' ── Where focus starts (defaultFocusID) ──
    f = { screen: "picker", auth: "", discovery: "idle", picked: false, users: 0, typingName: false }
    NxCheck(r, "focus picker", NxSignInDefaultFocus(f), "plex")
    f.screen = "find"
    NxCheck(r, "focus find, searching", NxSignInDefaultFocus(f), "find")
    f.discovery = "several"
    NxCheck(r, "focus find, several", NxSignInDefaultFocus(f), "found-0")
    f.discovery = "none"
    NxCheck(r, "focus find, none", NxSignInDefaultFocus(f), "type")
    f.screen = "type"
    NxCheck(r, "focus typed address", NxSignInDefaultFocus(f), "address")
    f.screen = "plexCreds"
    NxCheck(r, "focus plex credentials", NxSignInDefaultFocus(f), "plexEmail")
    f.screen = "signin"
    NxCheck(r, "focus sign-in, no users", NxSignInDefaultFocus(f), "username")
    f.users = 2
    NxCheck(r, "focus sign-in, users", NxSignInDefaultFocus(f), "user-0")
    f.typingName = true
    NxCheck(r, "focus sign-in, someone else", NxSignInDefaultFocus(f), "username")
    f.picked = true
    NxCheck(r, "focus sign-in, user picked", NxSignInDefaultFocus(f), "password")
    f.auth = "quick"
    NxCheck(r, "focus Quick Connect code", NxSignInDefaultFocus(f), "usePassword")
    for each auth in ["checking", "signing", "plex"]
        f.auth = auth
        NxCheck(r, "focus " + auth, NxSignInDefaultFocus(f), "cancel")
    end for

    ' ── Copy ──
    c = NxSignInCopy()
    NxCheck(r, "FIND MY SERVER is the button's name", c.findButton, "FIND MY SERVER")
    all = []
    for each k in c
        all.Push(c[k])
    end for
    for each kind in ["jellyfin", "emby"]
        all.Push(NxSignInConnectTitle(kind))
        all.Push(NxSignInFindIntro(kind))
        all.Push(NxSignInSwitchedKind(kind))
        all.Push(NxSignInCheckMessage("unreachable", -28, kind))
        all.Push(NxSignInCheckMessage("unreachable", 0, kind))
    end for
    for each code in [429, -6, -28, -35, 503, 0]
        all.Push(NxSignInPlexMessage(code))
    end for
    all.Push(NxSignInConnecting("server"))
    bad = []
    for each text in all
        if text = "" then bad.Push("(empty)")
        for i = 1 to Len(text)
            if Asc(Mid(text, i, 1)) > 126 then
                bad.Push(text)
                exit for
            end if
        end for
    end for
    NxCheck(r, "copy is plain text: no em dash, no emoji (" + all.Count().ToStr() + " lines)", bad.Join(" | "), "")
    ' The remote has no touch: a line names a button by its label and says
    ' press, never tap (the spec's rule for ports).
    tap = CreateObject("roRegex", "\btap\b", "i")
    taps = []
    for each text in all
        if tap.IsMatch(text) then taps.Push(text)
    end for
    NxCheck(r, "no line says tap", taps.Join(" | "), "")

    ' ── Plex, on-device email and password (NxPlexPasswordAuthResult; the
    ' request itself, like NxPlexAccount and NxPlexCreatePin, is network-only
    ' and isn't tested off-device) ──
    ok = NxPlexPasswordAuthResult(201, ParseJson("{""user"":{""authToken"":""tok123"",""username"":""chad""}}"))
    NxCheck(r, "password sign-in: success, token nested under user", ok.status + " " + ok.token + " " + ok.name, "ok tok123 chad")
    ok = NxPlexPasswordAuthResult(200, ParseJson("{""user"":{""authToken"":""tok456"",""title"":""Chad Mueller""}}"))
    NxCheck(r, "password sign-in: 200 counts, name falls back to title", ok.status + " " + ok.token + " " + ok.name, "ok tok456 Chad Mueller")
    ok = NxPlexPasswordAuthResult(201, ParseJson("{""authToken"":""tok789"",""username"":""flat""}"))
    NxCheck(r, "password sign-in: a flat response (no user key) still reads", ok.status + " " + ok.token + " " + ok.name, "ok tok789 flat")
    ok = NxPlexPasswordAuthResult(201, ParseJson("{""user"":{""authenticationToken"":""tokOld"",""username"":""legacy""}}"))
    NxCheck(r, "password sign-in: the older field name also reads", ok.status + " " + ok.token, "ok tokOld")
    bad = NxPlexPasswordAuthResult(401, ParseJson("{""error"":""Invalid email, username, or password.""}"))
    NxCheck(r, "password sign-in: 401 is wrong credentials, or an SSO-only account; the UI can't tell which", bad.status + " " + bad.token, "invalid ")
    err = NxPlexPasswordAuthResult(0, invalid)
    NxCheck(r, "password sign-in: no connection", err.status + " " + err.token, "error ")
    err = NxPlexPasswordAuthResult(500, invalid)
    NxCheck(r, "password sign-in: plex.tv's own error", err.status + " " + err.token, "error ")
    err = NxPlexPasswordAuthResult(201, ParseJson("{""user"":{""username"":""chad""}}"))
    NxCheck(r, "password sign-in: 2xx with no token is still an error", err.status, "error")
    ' No field the response carried crosses into what's returned except
    ' status, token and name: a password echoed back by a crafted response
    ' never reaches the caller, which is as close as an off-device test can
    ' get to proving the password is never logged (the print guard,
    ' tests/tools/check-guards.sh, covers the rest).
    leak = NxPlexPasswordAuthResult(201, ParseJson("{""user"":{""authToken"":""tok999"",""password"":""should-never-appear""}}"))
    NxCheck(r, "password sign-in: only status, token and name come back", leak.status + " " + leak.token + " " + leak.name + " " + NxToStr(leak.DoesExist("password")), "ok tok999 Plex false")

    print "sign-in flow cases (upstream SignInFlowTests):"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

function NxSignInTestServer(id as String, address as String) as Object
    return { name: "Server " + id, address: address, id: id }
end function

function NxSignInTestIds(servers as Object) as String
    ids = []
    for each s in servers
        ids.Push(s.id)
    end for
    return ids.Join(",")
end function

function NxSignInTestUsers(users as Object) as String
    out = []
    for each u in users
        out.Push(u.id + " " + u.name + " " + NxToStr(u.hasPassword))
    end for
    return out.Join("|")
end function

' A server answering from a table, as the Swift tests' FakeServer: routes by
' URL ({ code, text }), refused prefixes answer curl's -7, anything else 404.
' zero: every request refused by NxServerTransfer (code 0). timeout: a URL
' prefix that times out (-28). asked: every URL requested.
function NxSignInFake(routes as Object, refused as Object) as Object
    return { routes: routes, refused: refused, asked: [], timeouts: [], zero: false, timeout: "", delays: {}, clock: 0, tick: 0, fetch: NxSignInFakeFetch, elapsedMs: NxSignInFakeElapsed }
end function

' tick: ms the fake clock moves on each reading, as a real one does between
' two readings.
function NxSignInFakeElapsed() as Integer
    v = m.clock
    m.clock = m.clock + m.tick
    return v
end function

' delays: URL prefix to the ms an answer takes on the fake clock; one that
' takes longer than the request may answers -28 when its time is up.
function NxSignInFakeFetch(url as String, timeoutMs = 8000 as Integer) as Object
    m.asked.Push(url)
    m.timeouts.Push(timeoutMs)
    delay = 0
    ' Case-blind: on a TV an AA literal's keys come back lowercased.
    for each prefix in m.delays
        if LCase(Left(url, Len(prefix))) = LCase(prefix) then delay = m.delays[prefix]
    end for
    if delay > timeoutMs then
        m.clock = m.clock + timeoutMs
        return { code: -28, text: "" }
    end if
    m.clock = m.clock + delay
    if m.zero then return { code: 0, text: "" }
    if m.timeout <> "" and Left(url, Len(m.timeout)) = m.timeout then return { code: -28, text: "" }
    for each prefix in m.refused
        if Left(url, Len(prefix)) = prefix then return { code: -7, text: "" }
    end for
    if m.routes.DoesExist(url) then return m.routes[url]
    return { code: 404, text: "not found" }
end function

sub NxSignInTestSave(auth as Object)
    m.calls = m.calls + 1
end sub

' Writes a section of its own if it is ever called, so a dry run that saved
' would show in the registry's hash; the test deletes it again.
sub NxSignInTripwireSave(auth as Object)
    m.calls = m.calls + 1
    sec = CreateObject("roRegistrySection", "nxSignInTripwire")
    sec.Write("called", "1")
    sec.Flush()
end sub

' A SHA-1 of every registry section, key and value, so two can be compared
' without printing a value (the registry holds sign-in tokens).
function NxSignInRegistryDigest() as String
    d = CreateObject("roEVPDigest")
    d.Setup("sha1")
    ba = CreateObject("roByteArray")
    for each name in CreateObject("roRegistry").GetSectionList()
        sec = CreateObject("roRegistrySection", name)
        keys = sec.GetKeyList()
        values = sec.ReadMulti(keys)
        for each k in keys
            ba.FromAsciiString(name + Chr(10) + k + Chr(10) + NxToStr(values[k]) + Chr(10))
            d.Update(ba)
        end for
    end for
    return d.Final()
end function
