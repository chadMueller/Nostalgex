' Runs source/guide/DeepLink.brs: what a launch or roInput deep link names.
' Hand-written cases; deep links are the Roku's own, with nothing upstream to
' match. Returns the failure count.

function NxRunDeepLinkTests() as Integer
    r = { pass: 0, fail: 0 }

    NxCheck(r, "no args", FormatJson(NxDeepLinkFrom(invalid)), "null")
    NxCheck(r, "plain launch", FormatJson(NxDeepLinkFrom({ source: "homescreen" })), "null")
    NxCheck(r, "no mediaType", FormatJson(NxDeepLinkFrom({ contentId: "7" })), "null")
    NxCheck(r, "empty contentId", FormatJson(NxDeepLinkFrom({ contentId: " ", mediaType: "live" })), "null")
    link = NxDeepLinkFrom({ contentId: " 7 ", mediaType: "live", source: "external-control" })
    ' Field by field: on a TV, FormatJson writes an AA literal's keys
    ' lowercased ("contentid"), so the JSON text differs from the interpreter's.
    NxCheck(r, "link contentId", NxToStr(link.contentId), "7")
    NxCheck(r, "link mediaType", NxToStr(link.mediaType), "live")
    NxCheck(r, "link keys", link.Count().ToStr(), "2")

    channels = [
        { id: 1, number: 1, name: "ONE" },
        { id: 9, number: 7, name: "SEVEN" },
        { id: 7, number: 12, name: "TWELVE" },
        { id: 900001, number: 300, name: "FRANCHISE" },
    ]
    NxCheck(r, "id before number", NxDeepLinkChannel(channels, link).ToStr(), "2")
    NxCheck(r, "by number", NxDeepLinkChannel(channels, { contentId: "300", mediaType: "live" }).ToStr(), "3")
    NxCheck(r, "by franchise id", NxDeepLinkChannel(channels, { contentId: "900001", mediaType: "movie" }).ToStr(), "3")
    NxCheck(r, "unknown", NxDeepLinkChannel(channels, { contentId: "abc", mediaType: "live" }).ToStr(), "-1")
    NxCheck(r, "no channels", NxDeepLinkChannel(invalid, link).ToStr(), "-1")
    NxCheck(r, "no link", NxDeepLinkChannel(channels, invalid).ToStr(), "-1")
    NxCheck(r, "integer contentId", NxDeepLinkChannel(channels, NxDeepLinkFrom({ contentId: 300, mediaType: "live" })).ToStr(), "3")
    NxCheck(r, "boxed contentId", NxDeepLinkChannel(channels, NxDeepLinkFrom({ contentId: box(7), mediaType: "live" })).ToStr(), "2")
    NxCheck(r, "float contentId", NxDeepLinkChannel(channels, NxDeepLinkFrom({ contentId: 300.0, mediaType: "live" })).ToStr(), "3")
    NxCheck(r, "unset field", NxDeepLinkChannel(channels, {}).ToStr(), "-1")

    ' ── A sideloaded build's item link ──
    item = NxDeepLinkFrom({ contentId: "item:50929", mediaType: "movie" })
    NxCheck(r, "item link", NxDeepLinkItem(item, true), "50929")
    NxCheck(r, "item link in a store build", NxDeepLinkItem(item, false), "")
    NxCheck(r, "item link names no channel", NxDeepLinkChannel(channels, item).ToStr(), "-1")
    NxCheck(r, "item link, any case, spaces", NxDeepLinkItem(NxDeepLinkFrom({ contentId: " Item: ab12cd ", mediaType: "movie" }), true), "ab12cd")
    NxCheck(r, "item link without an id", NxDeepLinkItem({ contentId: "item:", mediaType: "movie" }, true), "")
    NxCheck(r, "channel link is no item", NxDeepLinkItem(link, true), "")
    NxCheck(r, "item: unset field", NxDeepLinkItem({}, true), "")
    NxCheck(r, "item: no link", NxDeepLinkItem(invalid, true), "")

    ' The airing it plays as (NxLinkedAiring).
    b = NxLinkedAiring({ ratingKey: "50929", title: "Lab Clip", type: "movie", year: 1990, duration: 10, videoCodec: "h264", serverIndex: 0 }, 1000)
    NxCheck(r, "airing from now", b.startSec.ToStr(), "1000")
    NxCheck(r, "airing for its length", b.endSec.ToStr(), "1600")
    NxCheck(r, "airing marked linked", FormatJson(b.linked), "true")
    NxCheck(r, "airing's item", b.ratingKey + " " + b.title + " " + b.videoCodec + " " + b.serverIndex.ToStr(), "50929 Lab Clip h264 0")
    b = NxLinkedAiring({ ratingKey: "1", title: "No Length", type: "movie" }, 1000)
    NxCheck(r, "airing without a length: two hours", b.endSec.ToStr(), "8200")

    print "deep link cases: "; r.pass; " passed,"; r.fail; " failed"
    return r.fail
end function
