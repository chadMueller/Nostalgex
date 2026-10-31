import Foundation

/// Pure subtitle preference logic shared by playback (`AppState`) and unit tests.
enum SubtitleSelectionLogic {

    /// Maps stored settings (`__system__` → device locale primary language).
    static func resolvedLanguageCode(storedCode: String, locale: Locale) -> String {
        if storedCode == "__system__" {
            if #available(tvOS 16.0, iOS 16.0, macOS 13.0, watchOS 9.0, *) {
                return locale.language.languageCode?.identifier ?? "en"
            }
            return localeLanguageFallback(locale)
        }
        return storedCode
    }

    private static func localeLanguageFallback(_ locale: Locale) -> String {
        let raw = locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if let idx = raw.firstIndex(of: "-") {
            return String(raw[..<idx])
        }
        return raw.isEmpty ? "en" : raw
    }

    /// Builds a comparable language tag from AVFoundation option metadata (matches previous AppState behavior).
    static func languageTagForComparison(extendedLanguageTag: String?, localeIdentifier: String?) -> String? {
        if let ext = extendedLanguageTag, !ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ext.lowercased()
        }
        guard let lid = localeIdentifier else { return nil }
        let raw = lid.replacingOccurrences(of: "_", with: "-").lowercased()
        if let idx = raw.firstIndex(of: "-") {
            return String(raw[..<idx])
        }
        return raw.isEmpty ? nil : raw
    }

    /// True when foreign-audio auto-subtitles should kick in: every audio track's language is
    /// KNOWN and none match the preferred audio language. Any unknown/empty/`und` tag disables
    /// the feature entirely — we can't be sure there is no match, so never guess.
    static func shouldAutoEnableSubtitles(audioTags: [String?], preferredAudioLowercased: String) -> Bool {
        guard !audioTags.isEmpty else { return false }
        for tag in audioTags {
            guard let t = tag?.lowercased(), !t.isEmpty, t != "und" else { return false }
            if tagMatchesPreferred(t, preferredAudioLowercased) { return false }
        }
        return true
    }

    /// Settings key for the subtitle language, shared with `AppState`.
    static let subtitleLanguageDefaultsKey = "nostalgex_subtitle_language"

    /// The subtitle language the viewer chose, resolved the way `AppState` resolves it.
    static func currentSubtitleLanguage(defaults: UserDefaults = .standard, locale: Locale = .current) -> String {
        let stored = defaults.string(forKey: subtitleLanguageDefaultsKey) ?? ""
        return resolvedLanguageCode(storedCode: stored.isEmpty ? "__system__" : stored, locale: locale)
    }

    /// ISO 639-2 to ISO 639-1, both the terminology codes ("deu") and the twenty
    /// bibliographic ones Matroska files often carry ("ger"). The string is the Roku app's
    /// `NxIso639Table` (roku/source/subtitles/SubtitleSettings.brs, issue #119) character
    /// for character, so both apps reduce every code the same way;
    /// `LanguageCodeMatchingTests` reads the Roku file and fails if they drift.
    static let iso639Pairs = "aar:aa abk:ab afr:af aka:ak alb:sq sqi:sq amh:am ara:ar arg:an arm:hy hye:hy asm:as ava:av ave:ae aym:ay aze:az bak:ba bam:bm baq:eu eus:eu bel:be ben:bn bis:bi bod:bo tib:bo bos:bs bre:br bul:bg bur:my mya:my cat:ca ces:cs cze:cs cha:ch che:ce chi:zh zho:zh chu:cu chv:cv cor:kw cos:co cre:cr cym:cy wel:cy dan:da deu:de ger:de div:dv dut:nl nld:nl dzo:dz ell:el gre:el eng:en epo:eo est:et ewe:ee fao:fo fas:fa per:fa fij:fj fin:fi fra:fr fre:fr fry:fy ful:ff geo:ka kat:ka gla:gd gle:ga glg:gl glv:gv grn:gn guj:gu hat:ht hau:ha heb:he her:hz hin:hi hmo:ho hrv:hr hun:hu ibo:ig ice:is isl:is ido:io iii:ii iku:iu ile:ie ina:ia ind:id ipk:ik ita:it jav:jv jpn:ja kal:kl kan:kn kas:ks kau:kr kaz:kk khm:km kik:ki kin:rw kir:ky kom:kv kon:kg kor:ko kua:kj kur:ku lao:lo lat:la lav:lv lim:li lin:ln lit:lt ltz:lb lub:lu lug:lg mac:mk mkd:mk mah:mh mal:ml mao:mi mri:mi mar:mr may:ms msa:ms mlg:mg mlt:mt mon:mn nau:na nav:nv nbl:nr nde:nd ndo:ng nep:ne nno:nn nob:nb nor:no nya:ny oci:oc oji:oj ori:or orm:om oss:os pan:pa pli:pi pol:pl por:pt pus:ps que:qu roh:rm ron:ro rum:ro run:rn rus:ru sag:sg san:sa sin:si slk:sk slo:sk slv:sl sme:se smo:sm sna:sn snd:sd som:so sot:st spa:es srd:sc srp:sr ssw:ss sun:su swa:sw swe:sv tah:ty tam:ta tat:tt tel:te tgk:tg tgl:tl tha:th tir:ti ton:to tsn:tn tso:ts tuk:tk tur:tr twi:tw uig:ug ukr:uk urd:ur uzb:uz ven:ve vie:vi vol:vo wln:wa wol:wo xho:xh yid:yi yor:yo zha:za zul:zu"

    /// `iso639Pairs` as a lookup, three letters to two.
    static let iso639ThreeToTwo: [String: String] = {
        var table: [String: String] = [:]
        for pair in iso639Pairs.split(separator: " ") {
            let kv = pair.split(separator: ":")
            table[String(kv[0])] = String(kv[1])
        }
        return table
    }()

    /// A tag as one comparable language code: "eng", "en", "en-US", "ger" and "deu" all
    /// reduce to "en" or "de". Two tags are the same language only when these are equal.
    ///
    /// Never compare first letters: "est" (Estonian) starts like "es", "arm" (Armenian) like
    /// "ar", "jav" (Javanese) like "ja", and "spa", "ger", "pol" or "swe" do not start like
    /// "es", "de", "pl" or "sv" at all. A three-letter code the table does not hold (such as
    /// "yue", Cantonese) stays as it is, so it can still match itself, as on Roku. Nil for
    /// an empty tag, anything that is not letters, and "und", "mul", "zxx" and "mis".
    static func primaryLanguage(_ tag: String?) -> String? {
        guard let raw = tag?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        let code = String(raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        guard !code.isEmpty, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        guard !["und", "mul", "zxx", "mis"].contains(code) else { return nil }
        if code.count == 3 { return iso639ThreeToTwo[code] ?? code }
        return code
    }

    /// Norwegian in every spelling: ISO 639-1 "no" (Norwegian), "nb" (Bokmål) and "nn"
    /// (Nynorsk), and their ISO 639-2 forms "nor", "nob" and "nno". Servers and players tag
    /// the same Norwegian track with any of them, so the apps treat them as one language.
    /// The one exception to the exact compare. The web tuner (scripts/nostalgex-language.js)
    /// and the Roku app (NxLanguageKey in SubtitleSettings.brs) hold the same set.
    static let norwegianCodes: Set<String> = ["no", "nb", "nn", "nor", "nob", "nno"]

    /// The code two tags are compared by: `primaryLanguage`, with every Norwegian code
    /// folded to "no". Everything else is unchanged.
    static func languageKey(_ tag: String?) -> String? {
        guard let code = primaryLanguage(tag) else { return nil }
        return norwegianCodes.contains(code) ? "no" : code
    }

    /// Same language, whichever code each side uses. A server labels tracks "eng"; the
    /// setting says "en". Regions are ignored: a server track has none.
    static func sameLanguage(_ a: String?, _ b: String?) -> Bool {
        guard let x = languageKey(a), let y = languageKey(b) else { return false }
        return x == y
    }

    /// The player's own track tags (AVFoundation's extended language tag, lowercased)
    /// against the setting: the same tag, or the same language with a region ("en-us" for
    /// "en"), as always; or both Norwegian in any spelling ("nb-no" for "no", "nn" for "nb").
    static func tagMatchesPreferred(_ tag: String, _ preferred: String) -> Bool {
        if tag == preferred || tag.hasPrefix(preferred + "-") { return true }
        func primary(_ s: String) -> String {
            String(s.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        }
        return norwegianCodes.contains(primary(tag)) && norwegianCodes.contains(primary(preferred))
    }

    /// Index of the best option for `preferredLowercased` (BCP‑47 primary or full tag); falls back to `0`.
    static func preferredTrackIndex(tags: [String?], preferredLowercased: String) -> Int {
        let want = preferredLowercased
        if let idx = tags.firstIndex(where: { tag in
            guard let t = tag?.lowercased() else { return false }
            return tagMatchesPreferred(t, want)
        }) {
            return idx
        }
        return 0
    }
}
