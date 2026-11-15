' Copyright (c) 2026 nostalgex-roku contributors, MIT License.

sub init()
    m.top.functionName = "runAction"
end sub

sub runAction()
    action = m.top.action
    ' A dry run (the sign-in tour) writes nothing: no install id either.
    if m.top.dryRun then GetGlobalAA().nxDryRunClientId = "dry-run-" + CreateObject("roDeviceInfo").GetRandomUUID()
    if action = "discover" then
        m.top.found = NxMbDiscover(m.top.kind)
        print "mediabrowser: "; m.top.found.Count(); " answers on this network"
        m.top.status = "found"
    else if action = "probe" then
        probe()
    else if action = "quickConnect" then
        quickConnect()
    else if action = "password" then
        password()
    else if action = "check" then
        check()
    end if
end sub

' Asks the address who it is before anyone types (NxSignInCheck): the
' server, with what it says about Quick Connect and its users, or the reason
' it can't be used. The server's own answer decides Jellyfin or Emby.
sub probe()
    result = NxSignInCheck(m.top.address, NxSignInLiveSend())
    if result.server = invalid then
        fail(NxSignInCheckMessage(result.reason, result.code, m.top.kind, m.top.address))
        return
    end if
    s = result.server
    print "mediabrowser: found a "; s.kind; " server; Quick Connect "; FormatJson(s.quickConnect); ", "; s.users.Count(); " users listed"
    m.top.server = s
    m.top.status = "checked"
end sub

' Jellyfin's Quick Connect: show the code, then poll for its approval as
' upstream does (NxSignInQuickConnectStep: every 2 s, a failed poll waits on,
' expired after 150), then sign in with it.
sub quickConnect()
    s = m.top.server
    start = NxMbQuickConnectStart(s.base)
    ' A String ("off", "notJellyfin") or an object: BrightScript can't compare
    ' an object to text.
    if NxIsString(start) then
        if start = "off" then fail(NxSignInCopy().quickConnectOff) else fail(NxSignInCopy().quickConnectNotJellyfin)
        return
    end if
    if start = invalid then
        fail(NxSignInCopy().quickConnectFailed)
        return
    end if
    m.top.code = start.code
    m.top.status = "code"
    attempt = 0
    while true
        Sleep(2000)
        if m.top.cancel then return
        attempt = attempt + 1
        approved = invalid
        if attempt <= 150 then approved = NxMbQuickConnectApproved(s.base, start.secret)
        if m.top.cancel then return
        stepNow = NxSignInQuickConnectStep(attempt, approved)
        if stepNow = "expired" then
            fail(NxSignInCopy().codeExpired)
            return
        end if
        if stepNow = "approved" then
            if m.top.dryRun then
                finish(NxSignInDryRunAuth())
            else
                finish(NxMbQuickConnectFinish(s.base, start.secret))
            end if
            return
        end if
    end while
end sub

' At launch, with the saved guide already up: a token the server now refuses
' sends the TV back to sign in, as a rejected Plex token does.
sub check()
    servers = ParseJson(NxPlexRegistry().Read("servers"))
    if type(servers) <> "roArray" or servers.Count() = 0 then return
    result = NxMbCheckSignIn(servers[0])
    print "mediabrowser: saved sign-in check: "; result
    if result = "rejected" then
        m.top.message = "The " + NxKindName(NxServerKind(servers[0])) + " server no longer accepts this TV's sign-in. Sign in again."
        m.top.status = "rejected"
    end if
end sub

sub password()
    if m.top.dryRun then
        finish(NxSignInDryRunAuth())
    else
        finish(NxMbSignIn(m.top.server.base, m.top.username, m.top.password))
    end if
    m.top.password = ""
end sub

sub finish(auth as Dynamic)
    ' Backed out while the server answered: saving now would sign this TV in
    ' to a server the viewer has left, maybe under a Plex sign-in begun since.
    if m.top.cancel then
        print "mediabrowser: sign-in answered after Back; not saved"
        return
    end if
    s = m.top.server
    result = NxSignInFinish(m.top.dryRun, auth, { server: s, save: NxMbSaverSave })
    if result = "unreached" then
        fail(NxSignInCheckMessage("unreachable", 0, s.kind))
        return
    end if
    if result = "refused" then
        fail(NxSignInCopy().incorrectPassword)
        return
    end if
    if m.top.dryRun then
        print "mediabrowser: dry run: signed in to "; s.kind; ", nothing saved"
    else
        print "mediabrowser: signed in to "; s.kind
    end if
    m.top.status = "signedIn"
end sub

' NxSignInFinish's saver; m is the saver, holding the task's server.
sub NxMbSaverSave(auth as Object)
    s = m.server
    NxMbSaveSignIn(s.kind, s.base, { name: s.name, id: NxToStr(s.id) }, auth)
end sub

sub fail(message as String)
    m.top.message = message
    m.top.status = "error"
    print "mediabrowser: "; message
end sub

' Saves a Jellyfin or Emby sign-in as this TV's only server and clears caches
' another account or server left (NxClaimAccountCaches), as a fresh Plex
' sign-in does.
sub NxMbSaveSignIn(kind as String, base as String, info as Object, auth as Object)
    serverId = auth.serverId
    if serverId = "" then serverId = info.id
    if serverId = "" then serverId = base
    server = {
        kind: kind, name: info.name, machineIdentifier: serverId, uri: base,
        userId: auth.userId, accessToken: auth.token, owned: true, checked: true
    }
    reg = NxPlexRegistry()
    reg.Delete("token")
    reg.Delete("needsPick")
    reg.Delete("serverChoices")
    reg.Delete("deselectedSections")
    reg.Delete("librarySections")
    reg.Write("kind", kind)
    reg.Write("servers", FormatJson([server]))
    reg.Flush()
    if NxClaimAccountCaches(kind + ":" + serverId + ":" + auth.userId, true) then print "mediabrowser: cleared the saved library left by another account, or by none recorded"
end sub
