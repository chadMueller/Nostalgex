' Test entry point. Replaces source/main.brs in the off-device run and in
' `scripts/deploy.sh --test`; never part of a normal build.
'
' On a TV every suite runs here in turn. tests/run.sh instead runs each
' NxTestWants("<name>") suite in its own interpreter, at once, with the two
' slowest (filter, qr) split across several (NxTestShard). It reads the suite
' names from this file, so a suite added here runs off the TV too.
sub Main(args = invalid as Dynamic)
    timer = CreateObject("roTimespan")
    failures = 0
    if NxTestWants("schedule") then
        failures = failures + NxRunScheduleTests("pkg:/tests/vectors/schedule.json")
        print "  schedule took "; timer.TotalMilliseconds(); " ms"
    end if
    timer.Mark()
    if NxTestWants("filter") then
        failures = failures + NxRunFilterTests("pkg:/tests/vectors/filter.json", "pkg:/data/channels-memberships.json", NxTestShard())
        print "  filter took "; timer.TotalMilliseconds(); " ms"
    end if
    timer.Mark()
    if NxTestWants("filter-golden") then failures = failures + NxRunFilterGoldenTests("pkg:/tests/vectors/filter-golden.json", "pkg:/data/channels.json", "pkg:/data/channels-memberships.json")
    if NxTestWants("rating-golden") then failures = failures + NxRunRatingGoldenTests("pkg:/tests/vectors/rating-golden.json")
    timer.Mark()
    if NxTestWants("lineup") then
        failures = failures + NxRunLineupTests("pkg:/tests/vectors/lineup.json")
        print "  lineup took "; timer.TotalMilliseconds(); " ms"
    end if
    timer.Mark()
    if NxTestWants("schedule-dst") then
        failures = failures + NxRunScheduleDSTGoldenTests("pkg:/tests/vectors/schedule-dst-golden.json", "pkg:/tests/vectors/schedule-dst-zones.json")
        print "  schedule dst took "; timer.TotalMilliseconds(); " ms"
    end if
    timer.Mark()
    if NxTestWants("schedule-parity") then
        failures = failures + NxRunScheduleParityGoldenTests("pkg:/tests/vectors/schedule-parity-golden.json", "pkg:/tests/vectors/schedule-parity-zones.json")
        print "  schedule parity took "; timer.TotalMilliseconds(); " ms"
    end if
    timer.Mark()
    if NxTestWants("franchise") then
        failures = failures + NxRunFranchiseTests("pkg:/tests/vectors/franchise-golden.json", "pkg:/tests/vectors/franchise.json", "pkg:/data/franchises.json")
        print "  franchise took "; timer.TotalMilliseconds(); " ms"
    end if
    timer.Mark()
    if NxTestWants("franchise-guide") then
        failures = failures + NxRunFranchiseGuideTests("pkg:/data/channels.json", "pkg:/data/franchises.json")
        print "  franchise guide took "; timer.TotalMilliseconds(); " ms"
    end if
    timer.Mark()
    if NxTestWants("enrichment") then
        failures = failures + NxRunEnrichmentTests("pkg:/tests/vectors/enrichment.json")
        print "  enrichment took "; timer.TotalMilliseconds(); " ms"
    end if
    timer.Mark()
    if NxTestWants("collections") then
        failures = failures + NxRunCollectionTests("pkg:/tests/vectors/collections.json", "pkg:/data/channels.json", "pkg:/data/franchises.json")
        print "  collections took "; timer.TotalMilliseconds(); " ms"
    end if
    if NxTestWants("subtitle") then failures = failures + NxRunSubtitleTests()
    if NxTestWants("guide-nav") then failures = failures + NxRunGuideNavTests()
    if NxTestWants("tune-queue") then failures = failures + NxRunTuneQueueTests()
    if NxTestWants("advance") then failures = failures + NxRunAdvanceTests()
    if NxTestWants("fallback") then failures = failures + NxRunFallbackTests()
    if NxTestWants("sleep-timer") then failures = failures + NxRunSleepTimerTests()
    if NxTestWants("deep-link") then failures = failures + NxRunDeepLinkTests()
    if NxTestWants("server-choice") then failures = failures + NxRunServerChoiceTests()
    if NxTestWants("server-resolve") then failures = failures + NxRunServerResolveTests()
    if NxTestWants("snapshot") then failures = failures + NxRunSnapshotTests()
    if NxTestWants("seasonal") then failures = failures + NxRunSeasonalTests("pkg:/tests/vectors/season-golden.json", "pkg:/data/channels.json")
    if NxTestWants("mediabrowser") then failures = failures + NxRunMediaBrowserTests("pkg:/tests/vectors/mediabrowser.json", "pkg:/tests/fixtures/mediabrowser-server.json")
    if NxTestWants("signin-flow") then failures = failures + NxRunSignInFlowTests()
    if NxTestWants("qr") then failures = failures + NxRunQrTests("pkg:/tests/vectors/qr.json", NxTestShard())
    if NxTestWants("version") then failures = failures + NxRunVersionTests()
    if failures = 0 then print "ALL TESTS PASSED" else print "TESTS FAILED"
end sub

' Whether this run includes the named suite: every suite when NxTestShard()
' is invalid (a TV), else only the one it names.
function NxTestWants(name as String) as Boolean
    shard = NxTestShard()
    return shard = invalid or shard.suite = name
end function
