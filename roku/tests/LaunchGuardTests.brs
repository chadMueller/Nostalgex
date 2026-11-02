' Runs source/util/LaunchGuard.brs: unfinished loads and TRY AGAIN, the cases
' transcribed from upstream's LaunchGuardTests.swift (the reinstall cases are
' tvOS keychain only). A stand-in registry section keeps the TV's own registry
' out of it. Returns the failure count.

function NxRunLaunchGuardTests() as Integer
    r = { pass: 0, fail: 0 }

    ' testTwoLoadsThatNeverFinishedAskBeforeATheThird
    reg = NxFakeRegistry()
    NxLoadStarted(reg)
    NxLoadRecordLaunch(reg)
    NxCheck(r, "one unfinished load does not ask", NxLoadShouldAsk(reg).ToStr(), "false")
    NxLoadStarted(reg)
    NxLoadRecordLaunch(reg)
    NxCheck(r, "two unfinished loads ask", NxLoadShouldAsk(reg).ToStr(), "true")

    ' testALoadThatEndsResetsTheCount
    reg = NxFakeRegistry()
    NxLoadStarted(reg)
    NxLoadRecordLaunch(reg)
    NxLoadStarted(reg)
    NxLoadEnded(reg)
    NxLoadRecordLaunch(reg)
    NxCheck(r, "a load that ends resets the count", NxLoadShouldAsk(reg).ToStr(), "false")
    NxCheck(r, "the count is gone", NxUnfinishedLoads(reg).ToStr(), "0")

    ' testANormalRelaunchCountsNothing
    reg = NxFakeRegistry()
    NxLoadRecordLaunch(reg)
    NxLoadRecordLaunch(reg)
    NxCheck(r, "a normal relaunch counts nothing", NxLoadShouldAsk(reg).ToStr(), "false")
    NxCheck(r, "the marker is gone after a launch", reg.Read("loadInFlight"), "")

    ' testAnInterruptedBackgroundRefreshCountsNothing: the saved guide shows,
    ' then the TV closes the app during the refresh behind it. Twice.
    reg = NxFakeRegistry()
    NxLaunchStep(reg, true)
    NxLaunchStep(reg, true)
    NxLoadRecordLaunch(reg)
    NxCheck(r, "a refresh behind a saved guide counts nothing", NxLoadShouldAsk(reg).ToStr(), "false")
    NxCheck(r, "its count stays 0", NxUnfinishedLoads(reg).ToStr(), "0")
    NxCheck(r, "a load behind a guide is not tracked", NxLoadTracked(true).ToStr(), "false")

    ' testABackgroundCallWithNoGuideYetIsAForegroundLoad /
    ' testARestoreThatKeepsDyingStillAsks: no saved guide to show, killed twice.
    NxCheck(r, "a load with no guide on screen is tracked", NxLoadTracked(false).ToStr(), "true")
    reg = NxFakeRegistry()
    NxLaunchStep(reg, false)
    NxLaunchStep(reg, false)
    NxLoadRecordLaunch(reg)
    NxCheck(r, "loads with no saved guide that keep dying ask", NxLoadShouldAsk(reg).ToStr(), "true")

    ' A saved guide shown clears the marker without resetting the count.
    reg = NxFakeRegistry()
    NxLaunchStep(reg, false)
    NxLaunchStep(reg, true)
    NxLoadRecordLaunch(reg)
    NxCheck(r, "a saved guide shown keeps the count", NxUnfinishedLoads(reg).ToStr(), "1")

    ' testTryAgainGivesTheFullAllowanceBack
    reg = NxFakeRegistry()
    reg.Write("unfinishedLoads", "2")
    NxLoadResetUnfinished(reg)
    NxCheck(r, "TRY AGAIN gives the full allowance back", NxLoadShouldAsk(reg).ToStr(), "false")

    ' testStartOverFromTheUnfinishedLoadsScreen / mid-load: START OVER is a
    ' sign-out, which ends the load with the count reset.
    reg = NxFakeRegistry()
    reg.Write("unfinishedLoads", "2")
    NxLoadStarted(reg)
    NxLoadEnded(reg)
    NxCheck(r, "START OVER clears the marker", reg.Read("loadInFlight"), "")
    NxCheck(r, "START OVER clears the count", NxLoadShouldAsk(reg).ToStr(), "false")

    ' A value that isn't a count reads as none.
    reg = NxFakeRegistry()
    reg.Write("unfinishedLoads", "x")
    NxCheck(r, "a junk count reads 0", NxUnfinishedLoads(reg).ToStr(), "0")
    reg.Write("unfinishedLoads", "-3")
    NxCheck(r, "a negative count reads 0", NxUnfinishedLoads(reg).ToStr(), "0")

    print "launch guard cases (upstream LaunchGuardTests): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function

' One launch as MainScene runs it with no guide on screen: the marker goes on
' as the load starts; a saved guide shown first ends it without resetting the
' count, and the refresh behind that guide carries no marker. Without one, the
' app is closed inside the load (upstream's launch(restoreWorks:...)).
sub NxLaunchStep(reg as Object, savedGuideShows as Boolean)
    NxLoadRecordLaunch(reg)
    if NxLoadTracked(false) then NxLoadStarted(reg)
    if savedGuideShows then NxLoadEnded(reg, false)
end sub

' A registry section in memory: Read, Write, Delete, Flush.
function NxFakeRegistry() as Object
    return {
        data: {},
        Read: function(k as String) as String
            v = m.data[k]
            if v = invalid then return ""
            return v
        end function,
        Write: function(k as String, v as String) as Boolean
            m.data[k] = v
            return true
        end function,
        Delete: function(k as String) as Boolean
            return m.data.Delete(k)
        end function,
        Flush: function() as Boolean
            return true
        end function
    }
end function
