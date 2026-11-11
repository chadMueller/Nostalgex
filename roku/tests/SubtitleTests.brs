' Runs source/subtitles/SubtitleSelection.brs against the cases in upstream's
' NostalgexTests/SubtitleSelectionLogicTests.swift, copied one for one: Swift
' can't run here, so these are transcribed, not generated. Returns the
' failure count.

function NxRunSubtitleTests() as Integer
    r = { pass: 0, fail: 0 }

    NxCheck(r, "resolved explicit", NxSubResolvedLanguage("fr", "en_US"), "fr")
    NxCheck(r, "resolved system de", NxSubResolvedLanguage("__system__", "de_DE"), "de")
    NxCheck(r, "resolved system ja", NxSubResolvedLanguage("__system__", "ja_JP"), "ja")

    NxCheck(r, "tag extended", NxToStr(NxSubLanguageTag("en-US", "fr_FR")), "en-us")
    NxCheck(r, "tag locale", NxToStr(NxSubLanguageTag(invalid, "es_ES")), "es")
    NxCheck(r, "tag underscore", NxToStr(NxSubLanguageTag(invalid, "pt_BR")), "pt")

    NxCheck(r, "index exact", NxSubPreferredTrackIndex(["en", "es"], "en").ToStr(), "0")
    NxCheck(r, "index region", NxSubPreferredTrackIndex(["es", "en-us"], "en").ToStr(), "1")
    NxCheck(r, "index fallback", NxSubPreferredTrackIndex(["de", "fr"], "ja").ToStr(), "0")
    NxCheck(r, "index nil", NxSubPreferredTrackIndex([invalid, "fr"], "en").ToStr(), "0")

    NxCheck(r, "auto foreign only", NxSubShouldAutoEnable(["fr"], "en").ToStr(), "true")
    NxCheck(r, "auto match present", NxSubShouldAutoEnable(["fr", "en"], "en").ToStr(), "false")
    NxCheck(r, "auto region match", NxSubShouldAutoEnable(["en-us"], "en").ToStr(), "false")
    NxCheck(r, "auto empty", NxSubShouldAutoEnable([], "en").ToStr(), "false")
    NxCheck(r, "auto nil", NxSubShouldAutoEnable([invalid], "en").ToStr(), "false")
    NxCheck(r, "auto und", NxSubShouldAutoEnable(["und"], "en").ToStr(), "false")
    NxCheck(r, "auto und mixed", NxSubShouldAutoEnable(["fr", "und"], "en").ToStr(), "false")
    NxCheck(r, "auto case", NxSubShouldAutoEnable(["EN"], "en").ToStr(), "false")
    NxCheck(r, "auto many foreign", NxSubShouldAutoEnable(["fr", "de", "ja"], "en").ToStr(), "true")

    ' The settings' defaults (#64): AppState.swift reads FOREIGN AUDIO as on
    ' until it is chosen, fullscreen subtitles as off.
    NxCheck(r, "fresh install: foreign on", FormatJson(NxSubtitleSettingsFrom("", "").foreign), "true")
    NxCheck(r, "fresh install: always off", FormatJson(NxSubtitleSettingsFrom("", "").always), "false")
    NxCheck(r, "foreign chosen off is kept", FormatJson(NxSubtitleSettingsFrom("", "0").foreign), "false")
    NxCheck(r, "foreign chosen on", FormatJson(NxSubtitleSettingsFrom("", "1").foreign), "true")
    NxCheck(r, "always chosen on", FormatJson(NxSubtitleSettingsFrom("1", "").always), "true")

    ' SUBTITLE and AUDIO LANGUAGE (#62): upstream's presets, and a choice
    ' reduced to its language, as tracks here carry none of the region.
    presets = NxLanguagePresets()
    NxCheck(r, "presets: fifteen languages and the device", presets.Count().ToStr(), "16")
    NxCheck(r, "presets: the device first", presets[0].code + "=" + presets[0].label, "__system__=MATCH ROKU LANGUAGE")
    NxCheck(r, "label of a preset", NxLanguageLabel("pt-BR"), "PORTUGUESE (BRAZIL)")
    NxCheck(r, "label of an unknown code", NxLanguageLabel("fi"), "FI")
    ' shortLabel (#118), the Now Playing panel's value.
    NxCheck(r, "short label: the device is system", NxLanguageShortLabel("__system__"), "SYSTEM")
    NxCheck(r, "short label: a code in capitals", NxLanguageShortLabel("en") + " " + NxLanguageShortLabel("pt-BR") + " " + NxLanguageShortLabel("zh-Hans"), "EN PT-BR ZH-HANS")
    NxCheck(r, "preferred: the device", NxPreferredLanguageFrom("__system__", "fr_CA"), "fr")
    NxCheck(r, "preferred: a choice beats the device", NxPreferredLanguageFrom("de", "en_US"), "de")
    NxCheck(r, "preferred: region dropped", NxPreferredLanguageFrom("pt-BR", "en_US"), "pt")
    NxCheck(r, "preferred: script dropped", NxPreferredLanguageFrom("zh-Hant", "en_US"), "zh")
    NxCheck(r, "preferred: no locale is english", NxPreferredLanguageFrom("__system__", ""), "en")
    listed = [{ Track: "a1", Language: "eng" }, { Track: "a2", Language: "ger" }, { Track: "a3", Language: "deu" }]
    NxCheck(r, "audio track: the first in the language", NxToStr(NxAudioTrackForLanguage(listed, "de")), "a2")
    NxCheck(r, "audio track: english", NxToStr(NxAudioTrackForLanguage(listed, "en")), "a1")
    NxCheck(r, "audio track: none leaves the player's", NxToStr(NxAudioTrackForLanguage(listed, "ja") = invalid), "true")
    NxCheck(r, "audio track: portuguese (brazil) takes por", NxToStr(NxAudioTrackForLanguage([{ Track: "x", Language: "eng" }, { Track: "y", Language: "por" }], NxPreferredLanguageFrom("pt-BR", "en_US"))), "y")
    NxCheck(r, "audio track: untagged never matches", NxToStr(NxAudioTrackForLanguage([{ Track: "x", Language: "" }, { Track: "y" }], "en") = invalid), "true")
    ' Issue #236, as PR #245 settled it: a track named a commentary is never picked while another track is listed.
    NxCheck(r, "audio track: a commentary first is passed over", NxToStr(NxAudioTrackForLanguage([{ Track: "c", Language: "eng", Name: "Director's Commentary" }, { Track: "m", Language: "eng", Name: "English 5.1" }], "en")), "m")
    NxCheck(r, "audio track: a commentary marked #uniq: too", NxToStr(NxAudioTrackForLanguage([{ Track: "c", Language: "eng", Name: "#uniq:Commentary" }, { Track: "m", Language: "eng" }], "en")), "m")
    NxCheck(r, "audio track: a commentary alone in the language leaves the player's choice", NxToStr(NxAudioTrackForLanguage([{ Track: "p", Language: "por", Name: "Portuguese" }, { Track: "c", Language: "eng", Name: "Commentary" }], "en") = invalid), "true")
    ' Issue #246: no pick in the language, and the player is on a commentary beside another track.
    plexFilm = [{ Track: "1", Language: "por", Name: "Portuguese" }, { Track: "2", Language: "eng", Name: "Director's Commentary" }]
    NxCheck(r, "off commentary: no english film track, so no pick by language", NxToStr(NxAudioTrackForLanguage(plexFilm, "en") = invalid), "true")
    NxCheck(r, "off commentary: the player on the commentary moves to the film's track", NxToStr(NxAudioTrackOffCommentary(plexFilm, "2")), "1")
    NxCheck(r, "off commentary: the player on the film's track stays", NxToStr(NxAudioTrackOffCommentary(plexFilm, "1") = invalid), "true")
    NxCheck(r, "off commentary: the first track that isn't one, in the file's order", NxToStr(NxAudioTrackOffCommentary([{ Track: "a", Language: "eng", Name: "Commentary 1" }, { Track: "b", Language: "eng", Name: "commentary 2" }, { Track: "c", Language: "jpn", Name: "Japanese" }, { Track: "d", Language: "kor" }], "a")), "c")
    NxCheck(r, "off commentary: commentaries alone, the player stays", NxToStr(NxAudioTrackOffCommentary([{ Track: "a", Language: "eng", Name: "Commentary 1" }, { Track: "b", Language: "eng", Name: "Commentary 2" }], "a") = invalid), "true")
    NxCheck(r, "off commentary: a track not in the list, the player stays", NxToStr(NxAudioTrackOffCommentary(plexFilm, "9") = invalid), "true")
    NxCheck(r, "off commentary: no current track, the player stays", NxToStr(NxAudioTrackOffCommentary(plexFilm, invalid) = invalid), "true")
    NxCheck(r, "off commentary: a track with no name isn't a commentary", NxToStr(NxAudioTrackOffCommentary([{ Track: "1", Language: "eng" }, { Track: "2", Language: "eng", Name: "Commentary" }], "1") = invalid), "true")
    NxCheck(r, "off commentary: Roku's #uniq: mark doesn't hide the word", NxToStr(NxAudioTrackOffCommentary([{ Track: "1", Language: "eng", Name: "#uniq:Commentary" }, { Track: "2", Language: "eng", Name: "English" }], "1")), "2")
    ' Issue #246: a server pick the player names a commentary (Emby keeps no MP4 track titles; the 43S45 lists them).
    labMp4 = [{ Track: "2", Language: "eng", Name: "Director's Commentary" }, { Track: "3", Language: "por", Name: "Portuguese" }]
    NxCheck(r, "past commentary: Emby's pick of the MP4's commentary goes to the film's track", NxToStr(NxAudioTrackPastCommentary(labMp4, "2", "eng")), "3")
    NxCheck(r, "past commentary: a pick that isn't a commentary stays", NxToStr(NxAudioTrackPastCommentary(labMp4, "3", "eng")), "3")
    NxCheck(r, "past commentary: no pick stays no pick", NxToStr(NxAudioTrackPastCommentary(labMp4, invalid, "eng") = invalid), "true")
    NxCheck(r, "past commentary: a film track in the pick's language comes before the first", NxToStr(NxAudioTrackPastCommentary([{ Track: "1", Language: "eng", Name: "Commentary" }, { Track: "2", Language: "por", Name: "Portuguese" }, { Track: "3", Language: "eng", Name: "English" }], "1", "eng")), "3")
    NxCheck(r, "past commentary: commentaries alone, the pick stays", NxToStr(NxAudioTrackPastCommentary([{ Track: "1", Language: "eng", Name: "Commentary 1" }, { Track: "2", Language: "eng", Name: "Commentary 2" }], "2", "eng")), "2")
    NxCheck(r, "past commentary: a pick with no language goes to the first that isn't one", NxToStr(NxAudioTrackPastCommentary([{ Track: "1", Language: "eng", Name: "Commentary" }, { Track: "2", Language: "por", Name: "Portuguese" }, { Track: "3", Language: "eng" }], "1", invalid)), "2")
    NxCheck(r, "audio track: commentaries alone go by language", NxToStr(NxAudioTrackForLanguage([{ Track: "p", Language: "por", Name: "Commentary (pt)" }, { Track: "c", Language: "eng", Name: "Commentary" }], "en")), "c")
    NxCheck(r, "audio track: a commentary in another language doesn't matter", NxToStr(NxAudioTrackForLanguage([{ Track: "c", Language: "ger", Name: "Kommentar / Commentary" }, { Track: "m", Language: "eng" }], "en")), "m")

    ' One code per language (#119): ISO 639-2's two forms to 639-1, so a
    ' look-alike three-letter code is another language.
    NxCheck(r, "code: est is estonian", NxToStr(NxSubComparableTag("est")), "et")
    NxCheck(r, "code: arm is armenian", NxToStr(NxSubComparableTag("arm")), "hy")
    NxCheck(r, "code: jav is javanese", NxToStr(NxSubComparableTag("jav")), "jv")
    NxCheck(r, "code: cze is czech", NxToStr(NxSubComparableTag("cze")), "cs")
    NxCheck(r, "code: ces is czech too", NxToStr(NxSubComparableTag("ces")), "cs")
    NxCheck(r, "code: ger and deu are de", NxToStr(NxSubComparableTag("ger")) + " " + NxToStr(NxSubComparableTag("deu")), "de de")
    NxCheck(r, "code: two letters pass through", NxToStr(NxSubComparableTag("es")), "es")
    NxCheck(r, "code: a region is dropped", NxToStr(NxSubComparableTag("pt-BR")) + " " + NxToStr(NxSubComparableTag("en_US")), "pt en")
    NxCheck(r, "code: case and spaces", NxToStr(NxSubComparableTag(" ENG ")), "en")
    NxCheck(r, "code: no two-letter form stays", NxToStr(NxSubComparableTag("yue")), "yue")
    NxCheck(r, "code: und mul zxx mis are none", NxToStr(NxSubComparableTag("und") = invalid and NxSubComparableTag("mul") = invalid and NxSubComparableTag("zxx") = invalid and NxSubComparableTag("mis") = invalid), "true")
    NxCheck(r, "code: empty is none", NxToStr(NxSubComparableTag("") = invalid and NxSubComparableTag(invalid) = invalid), "true")
    NxCheck(r, "audio track: spanish skips estonian", NxToStr(NxAudioTrackForLanguage([{ Track: "x", Language: "est" }, { Track: "y", Language: "spa" }], "es")), "y")
    NxCheck(r, "audio track: czech takes cze", NxToStr(NxAudioTrackForLanguage([{ Track: "x", Language: "eng" }, { Track: "y", Language: "cze" }], "cs")), "y")
    NxCheck(r, "subtitle pick: arabic skips armenian", NxSubPreferredTrackIndex([NxSubComparableTag("arm"), NxSubComparableTag("ara")], "ar").ToStr(), "1")
    NxCheck(r, "subtitle pick: finnish takes fin", NxSubPreferredTrackIndex([NxSubComparableTag("eng"), NxSubComparableTag("fin")], NxPreferredLanguageFrom("__system__", "fi_FI")).ToStr(), "1")
    NxCheck(r, "auto: cantonese audio is foreign", NxSubShouldAutoEnable([NxSubComparableTag("yue")], "en").ToStr(), "true")
    NxCheck(r, "auto: estonian audio is foreign to spanish", NxSubShouldAutoEnable([NxSubComparableTag("est")], "es").ToStr(), "true")

    ' Norwegian in every spelling is one language: no, nb (Bokmal), nn
    ' (Nynorsk), nor, nob, nno. Everything else keeps the exact compare.
    nors = ["no", "nb", "nn", "nor", "nob", "nno"]
    missed = ""
    for each a in nors
        for each b in nors
            if NxSubComparableTag(a) <> NxPreferredLanguageFrom(b, "en_US") then missed = missed + a + "/" + b + " "
        end for
    end for
    NxCheck(r, "norwegian: every spelling is one language", missed, "")
    NxCheck(r, "norwegian: nob and nno compare as no", NxToStr(NxSubComparableTag("nob")) + " " + NxToStr(NxSubComparableTag("NNO")) + " " + NxToStr(NxSubComparableTag("nb-NO")), "no no no")
    NxCheck(r, "norwegian: the TV set to nb_NO wants no", NxPreferredLanguageFrom("__system__", "nb_NO"), "no")
    NxCheck(r, "norwegian: the table is unchanged", NxIso639Table()["nob"] + " " + NxIso639Table()["nno"] + " " + NxIso639Table()["nor"], "nb nn no")
    NxCheck(r, "norwegian: bokmal viewer takes nor audio over swedish", NxToStr(NxAudioTrackForLanguage([{ Track: "x", Language: "swe" }, { Track: "y", Language: "nor" }], NxPreferredLanguageFrom("__system__", "nb_NO"))), "y")
    NxCheck(r, "norwegian: nynorsk setting takes nob audio", NxToStr(NxAudioTrackForLanguage([{ Track: "x", Language: "dan" }, { Track: "y", Language: "nob" }], NxPreferredLanguageFrom("nn", "en_US"))), "y")
    NxCheck(r, "norwegian: raw player tags match too", NxSubPreferredTrackIndex(["sv", "nb-no"], "no").ToStr() + NxSubPreferredTrackIndex(["da", "nn"], "nb").ToStr(), "11")
    NxCheck(r, "norwegian: bokmal audio is not foreign", NxSubShouldAutoEnable([NxSubComparableTag("nob")], NxPreferredLanguageFrom("nn", "en_US")).ToStr(), "false")
    NxCheck(r, "norwegian: danish swedish dutch stay apart", NxToStr(NxSubMatches("da", "no") or NxSubMatches("sv", "nb") or NxSubMatches("nl", "no") or NxSubComparableTag("dan") = "no" or NxSubComparableTag("nld") = "no"), "false")
    jf = [{ index: 1, language: "swe", channels: 6 }, { index: 2, language: "nor", channels: 2 }]
    NxCheck(r, "norwegian: jellyfin audio pick takes nor for nb", NxToStr(NxMbChosenAudioIndex(jf, [NxPreferredLanguageFrom("nb", "en_US")])), "2")
    NxCheck(r, "norwegian: jellyfin forced sub in nno for nb", NxToStr(NxMbForcedSub({ forcedSubs: [{ language: "nno", index: 4 }] }, NxPreferredLanguageFrom("nb", "en_US")) <> invalid), "true")

    ' The panel's audio track names: Roku's "#uniq:" marker isn't shown.
    NxCheck(r, "track name: #uniq: dropped", NxAudioTrackLabel("#uniq:Italiano", "ita", 0), "Italiano")
    NxCheck(r, "track name: #uniq: with the rest of the name", NxAudioTrackLabel("#uniq:English (Dolby Digital 5.1)", "eng", 1), "English (Dolby Digital 5.1)")
    NxCheck(r, "track name: #uniq: in any case, spaces trimmed", NxAudioTrackLabel(" #UNIQ: English ", "eng", 0), "English")
    NxCheck(r, "track name: a plain name is untouched", NxAudioTrackLabel("English", "eng", 0), "English")
    NxCheck(r, "track name: #uniq: only at the front", NxAudioTrackLabel("Director #uniq:Commentary", "eng", 0), "Director #uniq:Commentary")
    NxCheck(r, "track name: nothing after #uniq: is its language", NxAudioTrackLabel("#uniq:", "ita", 0), "ITA")
    NxCheck(r, "track name: no name is its language", NxAudioTrackLabel("", "spa", 0), "SPA")
    NxCheck(r, "track name: invalid name is its language", NxAudioTrackLabel(invalid, "spa", 2), "SPA")
    NxCheck(r, "track name: no name or language is its place", NxAudioTrackLabel(invalid, invalid, 2), "Track 3")

    ' pickLegibleOption (#63): a full track before a forced one.
    NxCheck(r, "pick: the full track over a forced one", NxSubPickIndex(["en", "en"], [true, false], "en").ToStr(), "1")
    NxCheck(r, "pick: a forced one when it's all there is", NxSubPickIndex(["en"], [true], "en").ToStr(), "0")
    NxCheck(r, "pick: forced in the language over another", NxSubPickIndex(["fr", "en"], [false, true], "en").ToStr(), "1")
    NxCheck(r, "pick: none in the language, the first", NxSubPickIndex(["fr", "de"], [false, false], "ja").ToStr(), "0")
    NxCheck(r, "pick: case of the tag", NxSubPickIndex(["EN"], [false], "en").ToStr(), "0")

    print "subtitle cases (upstream SubtitleSelectionLogicTests): "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function
