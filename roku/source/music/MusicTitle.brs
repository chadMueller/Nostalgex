' Copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Music-video titles to artist and song, as upstream's MusicTitleParser and
' the web tuner's parseTitle (scripts/nostalgex-music-brainz.js). Moved out of
' source/plex/PlexLibrary.brs (#73) so the lookup task loads only this.

' Ripped filenames down to searchable text, as MusicTitleParser.clean.
function NxCleanMusicTitle(raw as String) as String
    t = raw.Replace("_", " ")
    t = CreateObject("roRegex", "\[[^\]]*\]|\{[^}]*\}", "").ReplaceAll(t, "")
    t = CreateObject("roRegex", "\s*\((?:19|20)\d\d\)\s*$", "").ReplaceAll(t, "")
    t = CreateObject("roRegex", "\([^)]*(?:19|20)\d\d[^)]*\)", "").ReplaceAll(t, "")
    t = CreateObject("roRegex", "\b(official|video|hd|hq|lyrics?|remaster(?:ed)?|mv|xvid|dvdrip|vgb|prv)\b!?", "i").ReplaceAll(t, "")
    t = CreateObject("roRegex", "\s+", "").ReplaceAll(t, " ")
    return CreateObject("roRegex", "^[\s\-!.]+|[\s\-!.]+$", "").ReplaceAll(t, "")
end function

function NxStripFeaturing(s as String, artistSide as Boolean) as String
    if artistSide then
        re = CreateObject("roRegex", "\s+(?:ft\.?|feat\.?|featuring|with|and the)\s+.*$", "i")
    else
        re = CreateObject("roRegex", "\s+(?:ft\.?|feat\.?|featuring)\s+.*$", "i")
    end if
    return CreateObject("roRegex", "^[\s,]+|[\s,]+$", "").ReplaceAll(re.Replace(s, ""), "")
end function

function NxParseMusicTitle(raw as String) as Object
    cleaned = NxCleanMusicTitle(raw)
    dash = Instr(1, cleaned, " - ") - 1
    if dash > 0 then
        artist = NxStripFeaturing(Left(cleaned, dash), true)
        song = Mid(cleaned, dash + 4).Trim()
        nextDash = Instr(1, song, " - ") - 1
        if nextDash > 0 then song = Left(song, nextDash)
        song = NxStripFeaturing(song, false)
        if artist <> "" and song <> "" then return { artist: artist, song: song }
    end if
    lower = LCase(cleaned)
    byIdx = -1
    at = Instr(1, lower, " by ")
    while at > 0
        byIdx = at - 1
        at = Instr(at + 1, lower, " by ")
    end while
    if byIdx > 0 then
        song = NxStripFeaturing(Left(cleaned, byIdx), false)
        artist = NxStripFeaturing(Mid(cleaned, byIdx + 5), true)
        if artist <> "" and song <> "" then return { artist: artist, song: song }
    end if
    lone = CreateObject("roRegex", "^(.{2,}?)-(.+)$", "").Match(cleaned)
    if lone.Count() = 3 then
        if Instr(1, lone[1], " - ") = 0 then
            artist = NxStripFeaturing(lone[1], true)
            song = NxStripFeaturing(lone[2], false)
            if artist.Len() >= 2 and song.Len() >= 2 then return { artist: artist, song: song }
        end if
    end if
    return { artist: invalid, song: NxStripFeaturing(cleaned, false) }
end function
