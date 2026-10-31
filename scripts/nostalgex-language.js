// Language matching for the web tuner: is this audio or subtitle track the viewer's language?
//
// PARITY with tvOS and Roku
//   Nostalgex/Nostalgex/Services/SubtitleSelectionLogic.swift   iso639Pairs, primaryLanguage, sameLanguage
//   roku/source/subtitles/SubtitleSettings.brs                  NxIso639Table, NxSubComparableTag
//
// A Jellyfin or Emby track carries a three-letter ISO 639-2 code ("spa", "ger", "ces"); the
// viewer's setting, or the browser's, is a two-letter ISO 639-1 one ("es", "de", "cs"). Two
// tags are the same language only when both reduce to the same code through one table, so the
// compare is exact. Comparing first letters made "est" (Estonian) Spanish, "arm" (Armenian)
// Arabic, "jav" (Javanese) Japanese and "slo" (Slovak) Slovenian, and left "ces" (Czech)
// not matching "cs" (N-014, measured by scripts/nostalgex-language-match-smoke.mjs).
//
// The table is the Roku app's NxIso639Table (issue #119), character for character, and the
// Apple TV app carries the same string. The smoke reads the Roku file and fails if this
// string and that one differ, so change all three together.
//
// A three-letter code the table does not hold ("yue", Cantonese) stays as it is, so it can
// still match itself. "und", "mul", "zxx" and "mis" match nothing, not even each other.
//
// USAGE (browser: plain <script src="scripts/nostalgex-language.js">,
// node: `import "./nostalgex-language.js"`, then globalThis):
//
//   const L = window.NostalgexLanguage;
//   L.primaryLanguage('ger');        // 'de'
//   L.sameLanguage('ces', 'cs-CZ');  // true
//   L.sameLanguage('est', 'es');     // false

(function (global) {
  'use strict';

  /** ISO 639-2 to ISO 639-1, the terminology and bibliographic forms: three letters, a colon, two. */
  const ISO639_PAIRS = 'aar:aa abk:ab afr:af aka:ak alb:sq sqi:sq amh:am ara:ar arg:an arm:hy hye:hy asm:as ava:av ave:ae aym:ay aze:az bak:ba bam:bm baq:eu eus:eu bel:be ben:bn bis:bi bod:bo tib:bo bos:bs bre:br bul:bg bur:my mya:my cat:ca ces:cs cze:cs cha:ch che:ce chi:zh zho:zh chu:cu chv:cv cor:kw cos:co cre:cr cym:cy wel:cy dan:da deu:de ger:de div:dv dut:nl nld:nl dzo:dz ell:el gre:el eng:en epo:eo est:et ewe:ee fao:fo fas:fa per:fa fij:fj fin:fi fra:fr fre:fr fry:fy ful:ff geo:ka kat:ka gla:gd gle:ga glg:gl glv:gv grn:gn guj:gu hat:ht hau:ha heb:he her:hz hin:hi hmo:ho hrv:hr hun:hu ibo:ig ice:is isl:is ido:io iii:ii iku:iu ile:ie ina:ia ind:id ipk:ik ita:it jav:jv jpn:ja kal:kl kan:kn kas:ks kau:kr kaz:kk khm:km kik:ki kin:rw kir:ky kom:kv kon:kg kor:ko kua:kj kur:ku lao:lo lat:la lav:lv lim:li lin:ln lit:lt ltz:lb lub:lu lug:lg mac:mk mkd:mk mah:mh mal:ml mao:mi mri:mi mar:mr may:ms msa:ms mlg:mg mlt:mt mon:mn nau:na nav:nv nbl:nr nde:nd ndo:ng nep:ne nno:nn nob:nb nor:no nya:ny oci:oc oji:oj ori:or orm:om oss:os pan:pa pli:pi pol:pl por:pt pus:ps que:qu roh:rm ron:ro rum:ro run:rn rus:ru sag:sg san:sa sin:si slk:sk slo:sk slv:sl sme:se smo:sm sna:sn snd:sd som:so sot:st spa:es srd:sc srp:sr ssw:ss sun:su swa:sw swe:sv tah:ty tam:ta tat:tt tel:te tgk:tg tgl:tl tha:th tir:ti ton:to tsn:tn tso:ts tuk:tk tur:tr twi:tw uig:ug ukr:uk urd:ur uzb:uz ven:ve vie:vi vol:vo wln:wa wol:wo xho:xh yid:yi yor:yo zha:za zul:zu';

  /** `ISO639_PAIRS` as a lookup, three letters to two. */
  const THREE_TO_TWO = new Map(ISO639_PAIRS.split(' ').map(pair => pair.split(':')));

  /** Language tags that name no language. */
  const NO_LANGUAGE = ['und', 'mul', 'zxx', 'mis'];

  /**
   * A tag as one comparable code: "eng", "en", "en-US", "ger" and "deu" reduce to "en" or "de".
   * Case, surrounding spaces and a region ("-US", "_BR") do not matter. `null` for an empty
   * tag, anything that is not letters, and "und", "mul", "zxx" and "mis".
   */
  function primaryLanguage(tag) {
    if (tag == null) return null;
    const raw = String(tag).trim().toLowerCase();
    const code = raw.split(/[-_]/).find(part => part !== '') || '';
    if (!/^[a-z]+$/.test(code) || NO_LANGUAGE.includes(code)) return null;
    if (code.length === 3) return THREE_TO_TWO.get(code) || code;
    return code;
  }

  /** Same language, whichever code each side uses. False when either side names none. */
  function sameLanguage(a, b) {
    const x = primaryLanguage(a);
    const y = primaryLanguage(b);
    return x !== null && y !== null && x === y;
  }

  const api = { ISO639_PAIRS, THREE_TO_TWO, primaryLanguage, sameLanguage };

  global.NostalgexLanguage = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') {
    module.exports = api;
  }
})(typeof window !== 'undefined' ? window : globalThis);
