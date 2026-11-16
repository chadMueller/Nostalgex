' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Runs source/util/LiveChannels.brs, the live channels.json (N-074): which copy
' is accepted, that a rejected one leaves the cache as it was, the order the
' guide build chooses (cache, then bundled), and that a copy stored mid-session
' is not in a config already in hand. Hand-written cases on a stand-in registry
' (NxFakeRegistry, tests/LaunchGuardTests.brs) and a folder in tmp:. Returns the
' failure count.

function NxRunLiveChannelsTests(channelsPath as String) as Integer
    r = { pass: 0, fail: 0 }
    dir = "tmp:/nx-live-channels-test"
    NxLiveTestClean(dir)
    CreateDirectory(dir)

    ' ── Accept ──
    NxCheck(r, "the bundled file is accepted", FormatJson(NxLiveChannelsAccept(ReadAsciiFile(channelsPath), 0).ok), "true")
    bundled = NxLiveVersionOf(ReadAsciiFile(channelsPath))
    NxCheck(r, "the bundled file's version is read without parsing", FormatJson(bundled > 0), "true")
    NxCheck(r, "the same version as the build's is accepted", FormatJson(NxLiveChannelsAccept(NxLiveDoc(7, "", 2), 7).ok), "true")
    NxCheck(r, "a newer version is accepted", FormatJson(NxLiveChannelsAccept(NxLiveDoc(8, "", 2), 7).ok), "true")
    NxCheck(r, "an older version is rejected", NxLiveChannelsAccept(NxLiveDoc(6, "", 2), 7).reason, "older than this build's")
    NxCheck(r, "format 1 is accepted", FormatJson(NxLiveChannelsAccept(NxLiveDoc(8, """format"":1,", 2), 7).ok), "true")
    NxCheck(r, "a newer format is rejected", NxLiveChannelsAccept(NxLiveDoc(8, """format"":2,", 2), 7).reason, "format 2 is newer than this build reads")
    NxCheck(r, "a format that isn't a number is rejected", NxLiveChannelsAccept(NxLiveDoc(8, """format"":""x"",", 2), 7).reason, "bad format")
    NxCheck(r, "not JSON is rejected", NxLiveChannelsAccept("<html>502 Bad Gateway</html>", 7).reason, "not a JSON object")
    NxCheck(r, "a JSON array is rejected", NxLiveChannelsAccept("[1,2]", 7).reason, "not a JSON object")
    NxCheck(r, "empty text is rejected", NxLiveChannelsAccept("", 7).reason, "empty")
    NxCheck(r, "no text is rejected", NxLiveChannelsAccept(invalid, 7).reason, "no text")
    NxCheck(r, "an empty channels list is rejected", NxLiveChannelsAccept(NxLiveDoc(8, "", 0), 7).reason, "no channels")
    NxCheck(r, "no channels key is rejected", NxLiveChannelsAccept("{""version"":8,""bundles"":[{""id"":1}],""exclusiveRules"":[]}", 7).reason, "no channels")
    NxCheck(r, "no version is rejected", NxLiveChannelsAccept("{""bundles"":[{""id"":1}],""exclusiveRules"":[],""channels"":[{""id"":1,""name"":""A""}]}", 7).reason, "no version")
    NxCheck(r, "no bundles is rejected", NxLiveChannelsAccept("{""version"":8,""bundles"":[],""exclusiveRules"":[],""channels"":[{""id"":1,""name"":""A""}]}", 7).reason, "no bundles")
    NxCheck(r, "a channel with no name is rejected", NxLiveChannelsAccept("{""version"":8,""bundles"":[{""id"":1}],""exclusiveRules"":[],""channels"":[{""id"":1}]}", 7).reason, "a channel has no id or name")
    NxCheck(r, "an id twice is rejected", NxLiveChannelsAccept("{""version"":8,""bundles"":[{""id"":1}],""exclusiveRules"":[],""channels"":[{""id"":1,""name"":""A""},{""id"":1,""name"":""B""}]}", 7).reason, "channel id 1 twice")
    big = NxLiveDoc(8, "", 2) + String(NxLiveChannelsMaxBytes(), " ")
    NxCheck(r, "over 2 MB is rejected", NxLiveChannelsAccept(big, 7).reason, "too big")

    ' ── The version without a parse ──
    NxCheck(r, "version first in the file", NxLiveVersionOf("{" + Chr(10) + "  ""version"": 50," + Chr(10) + "  ""x"": 1}").ToStr(), "50")
    NxCheck(r, "no version in the head", NxLiveVersionOf("{""x"":1}").ToStr(), "-1")
    NxCheck(r, "version not a number", NxLiveVersionOf("{""version"":""a""}").ToStr(), "-1")

    ' ── Store: a good copy becomes the cache ──
    reg = NxFakeRegistry()
    now& = 1800000000
    res = NxLiveChannelsStore(NxLiveDoc(8, "", 2), dir, reg, now&, 7)
    NxCheck(r, "a good copy is stored", FormatJson(res.stored), "true")
    NxCheck(r, "the cache is that copy", NxLiveVersionOf(NxLiveReadFile(NxLiveChannelsPath(dir))).ToStr(), "8")
    NxCheck(r, "the stamp: version", reg.Read("version"), "8")
    NxCheck(r, "the stamp: when it worked", reg.Read("okAt"), now&.ToStr())
    NxCheck(r, "the stamp: when it was tried", reg.Read("tried"), now&.ToStr())
    NxCheck(r, "no temp file left", FormatJson(NxLiveTestHas(dir, "nostalgex-channels.json.new")), "false")

    ' ── Store: a bad copy is rejected and the cache is kept ──
    later& = now& + 90000
    for each bad in ["<html>", "{""version"":9,""bundles"":[{""id"":1}],""exclusiveRules"":[],""channels"":[]}", NxLiveDoc(9, """format"":5,", 2), NxLiveDoc(3, "", 2)]
        res = NxLiveChannelsStore(bad, dir, reg, later&, 7)
        NxCheck(r, "rejected: " + Left(bad, 24), FormatJson(res.stored), "false")
        NxCheck(r, "cache kept after: " + Left(bad, 24), NxLiveVersionOf(NxLiveReadFile(NxLiveChannelsPath(dir))).ToStr(), "8")
    end for
    NxCheck(r, "the stamp's version is kept", reg.Read("version"), "8")
    NxCheck(r, "the last good time is kept", reg.Read("okAt"), now&.ToStr())
    NxCheck(r, "the try is noted", reg.Read("tried"), later&.ToStr())

    ' ── Due ──
    fresh = NxFakeRegistry()
    NxCheck(r, "never tried: due", FormatJson(NxLiveChannelsDue(fresh, now&)), "true")
    good = NxFakeRegistry()
    good.Write("tried", now&.ToStr()) : good.Write("okAt", now&.ToStr())
    NxCheck(r, "after a good fetch, 23 h: not due", FormatJson(NxLiveChannelsDue(good, now& + 23 * 3600)), "false")
    NxCheck(r, "after a good fetch, 24 h: due", FormatJson(NxLiveChannelsDue(good, now& + 24 * 3600)), "true")
    failed = NxFakeRegistry()
    failed.Write("tried", now&.ToStr()) : failed.Write("okAt", (now& - 86400).ToStr())
    NxCheck(r, "after a failed try, 30 min: not due", FormatJson(NxLiveChannelsDue(failed, now& + 1800)), "false")
    NxCheck(r, "after a failed try, 1 h: due", FormatJson(NxLiveChannelsDue(failed, now& + 3600)), "true")

    ' ── Choose: the cache, then the bundled copy ──
    bdir = dir + "/b"
    CreateDirectory(bdir)
    root = dir + "/root"
    CreateDirectory(root)
    bpath = bdir + "/channels.json"
    NxLiveWriteFile(bpath, NxLiveDoc(7, "", 2))
    got = NxChannelsConfig(root, bpath)
    NxCheck(r, "no cache: the bundled copy", got.source, "bundled")
    NxCheck(r, "no cache: its version", got.config.version.ToStr(), "7")
    inHand = got.config
    NxLiveChannelsStore(NxLiveDoc(9, "", 3), root, NxFakeRegistry(), now&, 7)
    NxCheck(r, "a copy stored mid-session is not in the config in hand", inHand.version.ToStr() + "/" + inHand.channels.Count().ToStr(), "7/2")
    got = NxChannelsConfig(root, bpath)
    NxCheck(r, "the next build reads the cache", got.source, "cache")
    NxCheck(r, "the next build: its version", got.config.version.ToStr(), "9")
    NxCheck(r, "the next build: its channels", got.config.channels.Count().ToStr(), "3")
    NxLiveWriteFile(bpath, NxLiveDoc(12, "", 2))
    got = NxChannelsConfig(root, bpath)
    NxCheck(r, "an app update past the cache: the bundled copy", got.source + "/" + got.config.version.ToStr(), "bundled/12")
    NxLiveWriteFile(bpath, NxLiveDoc(7, "", 2))
    NxLiveWriteFile(NxLiveChannelsPath(root), "{""version"": 20, ""channels"": [")
    got = NxChannelsConfig(root, bpath)
    NxCheck(r, "a damaged cache: the bundled copy", got.source + "/" + got.config.version.ToStr(), "bundled/7")
    NxLiveWriteFile(NxLiveChannelsPath(root), NxLiveDoc(20, """format"":9,", 2))
    got = NxChannelsConfig(root, bpath)
    NxCheck(r, "a cache in a format this build doesn't read: the bundled copy", got.source, "bundled")
    DeleteFile(NxLiveChannelsPath(root))
    got = NxChannelsConfig(root, bpath)
    NxCheck(r, "cache gone: the bundled copy", got.source, "bundled")

    NxLiveTestClean(dir)
    print "live channels cases: "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' A channels.json with `n` channels, a version and extra top-level text.
function NxLiveDoc(version as Integer, extra as String, n as Integer) as String
    chans = []
    for i = 1 to n
        chans.Push("{""id"":" + i.ToStr() + ",""name"":""CH " + i.ToStr() + """}")
    end for
    return "{""version"":" + version.ToStr() + "," + extra + """bundles"":[{""id"":1,""name"":""B""}],""exclusiveRules"":[],""channels"":[" + chans.Join(",") + "]}"
end function

function NxLiveTestHas(dir as String, name as String) as Boolean
    for each f in ListDir(dir)
        if f = name then return true
    end for
    return false
end function

sub NxLiveTestClean(dir as String)
    for each part in ["/b", "/root"]
        for each f in ListDir(dir + part)
            DeleteFile(dir + part + "/" + f)
        end for
        DeleteDirectory(dir + part)
    end for
    for each f in ListDir(dir)
        DeleteFile(dir + "/" + f)
    end for
    DeleteDirectory(dir)
end sub
