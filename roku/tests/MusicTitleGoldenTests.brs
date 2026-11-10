' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Holds the music video title cleanup (source/plex/PlexLibrary.brs, issue #239,
' N-034) to upstream's scripts/music-title-golden.json, copied unchanged to
' tests/vectors/: the cases the web tuner's nostalgex-music-title-smoke.mjs
' reads. `clean` is NxCleanMusicTitle, the same text in and out; `parse` is
' NxParseMusicTitle, the artist (null when there is none) and the song.
' Then tests/vectors/music-title.json (tests/gen-music-title.mjs): what the web
' module itself answers for every one of those inputs, cleaned and parsed, so
' the port is held to the module as well as to the file.
' Returns the failure count.

function NxRunMusicTitleGoldenTests(goldenPath as String, vectorsPath as String) as Integer
    golden = ParseJson(ReadAsciiFile(goldenPath))
    vectors = ParseJson(ReadAsciiFile(vectorsPath))
    if golden = invalid or golden.clean = invalid or golden.parse = invalid then
        print "FAIL cannot read "; goldenPath
        return 1
    end if
    if vectors = invalid or vectors.titles = invalid then
        print "FAIL cannot read "; vectorsPath
        return 1
    end if
    r = { pass: 0, fail: 0 }
    for each c in golden.clean
        NxCheck(r, "clean " + FormatJson(c.in), NxCleanMusicTitle(c.in), c.out)
    end for
    for each c in golden.parse
        NxCheck(r, "parse " + FormatJson(c.in), NxMusicTitleParsed(c.in), FormatJson(c.artist) + " " + FormatJson(c.song))
    end for
    ' A golden file that lost its cases would pass with nothing checked.
    NxCheck(r, "the golden file has its cases", FormatJson(golden.clean.Count() >= 37 and golden.parse.Count() >= 8), "true")
    print "music title golden cases (upstream music-title-golden.json):"; r.pass; " passed,"; r.fail; " failed"

    v = { pass: 0, fail: 0 }
    for each t in vectors.titles
        NxCheck(v, "web clean " + FormatJson(t.in), NxCleanMusicTitle(t.in), t.clean)
        NxCheck(v, "web parse " + FormatJson(t.in), NxMusicTitleParsed(t.in), FormatJson(t.artist) + " " + FormatJson(t.song))
    end for
    NxCheck(v, "the web vectors cover every golden input", FormatJson(vectors.titles.Count() >= golden.clean.Count()), "true")
    print "music title vectors (the web module on the golden inputs):"; v.pass; " passed,"; v.fail; " failed"
    return r.fail + v.fail
end function

' The parse as one comparable line: the artist as JSON (null when none), then the song.
function NxMusicTitleParsed(raw as String) as String
    p = NxParseMusicTitle(raw)
    return FormatJson(p.artist) + " " + FormatJson(p.song)
end function
