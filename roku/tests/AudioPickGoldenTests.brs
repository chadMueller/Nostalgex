' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Holds the audio pick to upstream's scripts/audio-pick-golden.json (issue #279),
' copied unchanged to tests/vectors/: the Apple TV's AudioTrackSelectionTests as
' vectors for scripts/nostalgex-audio-pick.js.
'
'   commentaryTitles   NxIsCommentaryTitle: the titles that count and don't.
'   jellyfinAndEmby    the file's audio streams are read as the scan reads them
'                      (NxMbAudioTracks, from MediaStreams) and picked as the
'                      tune does: NxMbChosenAudioIndex with AUDIO LANGUAGE when
'                      the case gives one, else the browser-language rule, which
'                      is NxMbPreferredAudioIndex. Expect an index, or null for
'                      "leave it to the server" (invalid here).
'   plex               the Roku has no Plex server-stream pick (#246: Plex ignores
'                      an audio stream id on a start, measured 2026-11-12). What it
'                      has is the direct play's rule on the player's own list,
'                      NxAudioTrackOffCommentary, so these run through it: "selected"
'                      is the track the player is on; the answer is the track it
'                      is moved to, else the one it stays on, and with none
'                      selected the first (#299: no current track is the first).
'
' The Roku reads AUDIO LANGUAGE alone for a viewer who chose one and the TV's own
' language for one who didn't (NxMbViewerLanguages). A case with no audioLanguage
' is the web tuner's browser-language rule, so it is held to NxMbPreferredAudioIndex
' as the golden gives it, and also run the way the tune runs it for a viewer on Auto
' (NxMbChosenAudioIndex with that one language); a difference there is printed.
' Returns the failure count.

function NxRunAudioPickGoldenTests(goldenPath as String) as Integer
    golden = ParseJson(ReadAsciiFile(goldenPath))
    if golden = invalid or golden.commentaryTitles = invalid or golden.jellyfinAndEmby = invalid or golden.plex = invalid then
        print "FAIL cannot read "; goldenPath
        return 1
    end if
    r = { pass: 0, fail: 0 }

    for each t in golden.commentaryTitles.yes
        NxCheck(r, "commentary title: " + t, NxToStr(NxIsCommentaryTitle(t)), "true")
    end for
    for each t in golden.commentaryTitles.no
        NxCheck(r, "not a commentary title: '" + t + "'", NxToStr(NxIsCommentaryTitle(t)), "false")
    end for

    autoDiffers = []
    for each c in golden.jellyfinAndEmby
        streams = []
        for each s in c.streams
            ms = { Type: "Audio", Index: s.index }
            if s.lang <> invalid then ms.Language = s.lang
            if s.channels <> invalid then ms.Channels = s.channels
            if s.isDefault <> invalid then ms.IsDefault = s.isDefault
            if s.title <> invalid then ms.Title = s.title
            if s.displayTitle <> invalid then ms.DisplayTitle = s.displayTitle
            streams.Push(ms)
        end for
        tracks = NxMbAudioTracks({ MediaStreams: streams })
        want = c.expect
        if tracks = invalid then
            NxCheck(r, "jellyfin/emby: " + c.name, NxToStr(want = invalid), "true")
        else
            browser = []
            for each l in c.preferredLanguages
                browser.Push(NxPreferredLanguageFrom("__system__", Substitute("{0}", l).Replace("-", "_")))
            end for
            if c.audioLanguage <> invalid and c.audioLanguage <> "__system__" then
                got = NxMbChosenAudioIndex(tracks, [NxPreferredLanguageFrom(c.audioLanguage, "en_US")])
            else
                got = NxMbPreferredAudioIndex(tracks, browser)
                tune = NxMbChosenAudioIndex(tracks, [browser[0]])
                if NxToStr(tune) <> NxToStr(want) then autoDiffers.Push(c.name + " (the tune on Auto picks " + NxToStr(tune) + ", the file says " + NxToStr(want) + ")")
            end if
            NxCheck(r, "jellyfin/emby: " + c.name, NxToStr(got), NxToStr(want))
        end if
    end for

    for each c in golden.plex
        listed = []
        current = invalid
        first = invalid
        for each s in c.streams
            track = { Track: NxToStr(s.id), Language: "eng", Name: s.title }
            listed.Push(track)
            if first = invalid then first = track.Track
            if s.selected = 1 then current = track.Track
        end for
        moved = NxAudioTrackOffCommentary(listed, current)
        if moved <> invalid then
            got = moved
        else if current <> invalid then
            got = current
        else
            got = first
        end if
        NxCheck(r, "plex (the direct play's rule): " + c.name, NxToStr(got), NxToStr(c.expect))
    end for

    print "audio pick golden: "; r.pass; " passed, "; r.fail; " failed ("; golden.commentaryTitles.yes.Count() + golden.commentaryTitles.no.Count(); " titles, "; golden.jellyfinAndEmby.Count(); " jellyfin/emby cases, "; golden.plex.Count(); " plex cases)"
    for each d in autoDiffers
        print "audio pick golden: on Auto the Roku differs from the file: "; d
    end for
    return r.fail
end function
