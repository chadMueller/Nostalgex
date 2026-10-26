' Runs source/util/AppVersion.brs: the VERSION line, with and without the
' manifest's nx_build; and the data space in source/util/Values.brs, which a
' release (no nx_data_ns) must leave at the names it always had. Returns the
' failure count.

function NxRunVersionTests() as Integer
    r = { pass: 0, fail: 0 }
    NxCheck(r, "version and build", NxFormatVersionLabel("1", "0", "2", "cca0d38a1b2c"), "VERSION 1.0.2 (cca0d38a1b2c)")
    NxCheck(r, "no nx_build", NxFormatVersionLabel("1", "0", "2", ""), "VERSION 1.0.2")
    NxCheck(r, "padded build_version", NxFormatVersionLabel("1", "0", "00002", ""), "VERSION 1.0.2")
    NxCheck(r, "missing number", NxFormatVersionLabel("", "0", "2", " "), "VERSION ?.0.2")

    ' Data space, as this build's own manifest has it. The repo's manifest
    ' (off the TV, and what release.sh ships) has no nx_data_ns: every name
    ' as before. An NX_TEST_DATA=1 deploy.sh --test build checks its own.
    manifest = ReadAsciiFile("pkg:/manifest")
    if Instr(1, manifest, "nx_data_ns=") = 0 then
        NxCheck(r, "release: no data space", NxDataSpace(), "")
        NxCheck(r, "release: registry section unchanged", NxRegName("guide", NxDataSpace()), "guide")
        NxCheck(r, "release: cache root unchanged", NxCacheRoot(), "cachefs:")
        NxCheck(r, "release: snapshot dir unchanged", NxSnapshotDir(), "cachefs:/nostalgex-library")
        NxCheck(r, "release: owner file unchanged", NxCacheOwnerPath(), "cachefs:/nostalgex-owner.txt")
        NxCheck(r, "release: VERSION line has no TEST DATA", Instr(1, NxVersionLabel(), "TEST DATA").ToStr(), "0")
    else
        NxCheck(r, "test data: its space", NxDataSpace(), "nxtest")
        NxCheck(r, "test data: cache root", NxCacheRoot(), "cachefs:/nxtest")
        NxCheck(r, "test data: snapshot dir", NxSnapshotDir(), "cachefs:/nxtest/nostalgex-library")
        NxCheck(r, "test data: VERSION line says so", (Instr(1, NxVersionLabel(), "TEST DATA") > 0).ToStr(), "true")
    end if
    ' A test build's SIGN OUT: NxClearAccountCaches on the render thread,
    ' where roFileSystem isn't available, as it isn't in this interpreter.
    ' With the test data space it must clear without one (it crashed).
    g = GetGlobalAA()
    keepSpace = g.nxDataSpace
    keepMade = g.nxCacheRootMade
    g.nxDataSpace = "nxtest"
    g.nxCacheRootMade = invalid
    NxCheck(r, "test data sign-out: cache root", NxCacheRoot(), "cachefs:/nxtest")
    WriteAsciiFile("cachefs:/nxtest/nostalgex-guide.json", "{}")
    NxClearAccountCaches()
    NxCheck(r, "test data sign-out: clears its own guide", NxHasValue(ListDir("cachefs:/nxtest"), "nostalgex-guide.json").ToStr(), "false")
    NxCheck(r, "test data sign-out: snapshot dir", NxSnapshotDir(), "cachefs:/nxtest/nostalgex-library")
    DeleteDirectory("cachefs:/nxtest")
    g.nxDataSpace = keepSpace
    g.nxCacheRootMade = keepMade

    ' What a manifest value gives.
    NxCheck(r, "space: none", NxDataSpaceFrom(invalid), "")
    NxCheck(r, "space: empty", NxDataSpaceFrom(""), "")
    NxCheck(r, "space: nothing usable", NxDataSpaceFrom(" -/ "), "")
    NxCheck(r, "space: deploy.sh's", NxDataSpaceFrom("nxtest"), "nxtest")
    NxCheck(r, "space: cleaned", NxDataSpaceFrom(" NX-Test/1 "), "nxtest1")
    NxCheck(r, "space: at most 16", NxDataSpaceFrom("abcdefghijklmnopqrstuvwxyz"), "abcdefghijklmnop")
    NxCheck(r, "test build: registry section", NxRegName("guide", "nxtest"), "nxtest-guide")
    NxCheck(r, "test build: cache root", NxCacheRootFor("cachefs:", "nxtest"), "cachefs:/nxtest")
    NxCheck(r, "release: cache root for none", NxCacheRootFor("cachefs:", ""), "cachefs:")
    print "version cases:"; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function
