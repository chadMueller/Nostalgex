' Which of MY COLLECTIONS' two categories a server collection belongs in.
'
' Copyright (c) 2024 Chad Mueller / Muell Haus Inc. (Nostalgex), MIT License.
' Port copyright (c) 2026 nostalgex-roku contributors, MIT License.
'
' Source: the Apple TV app's Services/CollectionClassifier.swift, at the
' commit in data/UPSTREAM. FRANCHISES ("franchises") is movie series and
' sequels, airing with the found franchises from CH 310 to 399; OTHER
' COLLECTIONS ("custom") is actors, directors and the viewer's own sets,
' from CH 400 to 499.
' The web tuner has no classifier, so the cases in tests/CollectionTests.brs
' are transcribed from upstream's CollectionClassifierTests.swift and
' CollectionShowsTests.swift.
'
' Differences from upstream, all in text handling:
'   - Lowercasing is NxFranchiseLower (JS toLowerCase), where Swift's
'     lowercased() is the same outside a few special cases.
'   - Swift trims Unicode punctuation (the P categories) from each title
'     word. Here that is ASCII's P characters and the curly quotes, dashes,
'     ellipsis, inverted marks and guillemets (NxClassifyIsPunct).
'   - Swift counts and drops Characters (grapheme clusters); this counts
'     and drops code points. They differ only on combining marks and emoji.

' classify(title:items:enrichmentFor:). items are the collection's resolved
' library items, films and episodes. An item's TMDB collection id is
' item.enrichment.franchiseID (NxFranchiseEnrichment); an item without
' enrichment has none, as upstream's lookup gives nil.
function NxCollectionClassify(title as Dynamic, items as Object) as String
    ' Shows: every episode carries its show's title, so the word rules below
    ' would call any collection of shows a franchise. The films alone decide;
    ' a collection with no films is the viewer's own set.
    films = []
    for each it in items
        if it.type = "movie" then films.Push(it)
    end for
    if films.Count() < items.Count() then
        if films.Count() = 0 then return "custom"
        return NxCollectionClassify(title, films)
    end if

    cleaned = NxToStr(title)
    cleaned = CreateObject("roRegex", " Collection", "i").ReplaceAll(cleaned, "")
    cleaned = CreateObject("roRegex", "Collection", "i").ReplaceAll(cleaned, "")
    cleaned = NxClassifyReplace(cleaned, "'s", "")
    cleaned = NxClassifyReplace(cleaned, Chr(8217) + "s", "")
    cleaned = NxClassifyTrimSpaces(cleaned)
    lower = NxFranchiseLower(cleaned)

    ' 0. Service-generated lists ("IMDb Popular", "Anilist Top Rated"), before
    '    the franchise id so a popular list holding two films of one series
    '    still lands in OTHER COLLECTIONS.
    if NxClassifyIsGeneratedList(lower) then return "custom"
    ' 0.5 Two or more films sharing a TMDB collection.
    if NxClassifySharesFranchiseID(items) then return "franchises"
    ' 1. Known franchise names.
    for each name in NxClassifyKnownFranchises()
        if Instr(1, lower, name) > 0 then return "franchises"
    end for
    ' 2. Franchise keywords.
    for each word in ["saga", "trilogy", "universe", "chronicles", "franchise", "cinematic"]
        if Instr(1, lower, word) > 0 then return "franchises"
    end for
    ' 3. A word or a title prefix shared by 3 or more titles.
    if items.Count() >= 3 and NxClassifyHasRepeatingNames(items) then return "franchises"
    ' 4. The collection's own name in 2 or more of its titles.
    if NxClassifyNameInTitles(lower, items) then return "franchises"
    ' 5. Everything else, actor and director sets included.
    return "custom"
end function

' String.replacingOccurrences, case-sensitive.
function NxClassifyReplace(s as String, find as String, repl as String) as String
    out = ""
    rest = s
    i = Instr(1, rest, find)
    while i > 0
        out = out + Left(rest, i - 1) + repl
        rest = Mid(rest, i + find.Len())
        i = Instr(1, rest, find)
    end while
    return out + rest
end function

' trimmingCharacters(in: .whitespaces): spaces and tabs, not line breaks.
function NxClassifyTrimSpaces(s as String) as String
    return CreateObject("roRegex", "^[ \t" + Chr(160) + "]+|[ \t" + Chr(160) + "]+$", "").ReplaceAll(s, "")
end function

function NxClassifyIsGeneratedList(lower as String) as Boolean
    sources = ["anilist", "myanimelist", "mal ", "imdb", "tmdb", "themoviedb", "letterboxd", "trakt", "tvdb", "rotten tomatoes", "metacritic"]
    for each s in sources
        if Instr(1, lower, s) > 0 then return true
    end for
    phrases = ["popular", "trending", "top rated", "highest rated", "best rated", "most watched", "most popular", "recently added", "recently released", "newly added", "new releases", "favorited", "recommended", "watchlist", "top 250", "top 100", "top 50", "top 10"]
    for each p in phrases
        if Instr(1, lower, p) > 0 then return true
    end for
    return false
end function

' Two or more items with the same TMDB collection id.
function NxClassifySharesFranchiseID(items as Object) as Boolean
    counts = {}
    for each it in items
        fid = NxFranchiseEnrichment(it).fid
        if fid <> invalid then
            k = fid.ToStr()
            if counts[k] = invalid then counts[k] = 0
            counts[k] = counts[k] + 1
            if counts[k] >= 2 then return true
        end if
    end for
    return false
end function

function NxClassifyKnownFranchises() as Object
    return [
        "batman", "superman", "spider-man", "spiderman",
        "wolverine", "x-men", "deadpool", "venom",
        "wonder woman", "aquaman", "the flash",
        "iron man", "captain america", "thor", "ant-man",
        "black panther", "hulk", "avengers",
        "guardians of the galaxy",
        "fantastic four", "blade",
        "hellboy", "spawn", "the crow",
        "teenage mutant ninja turtles", "tmnt",
        "james bond", "007",
        "jack ryan", "jack reacher",
        "the equalizer",
        "the conjuring", "conjuring", "annabelle",
        "final destination",
        "a nightmare on elm street", "elm street",
        "friday the 13th",
        "child's play", "chucky",
        "the exorcist", "the omen",
        "evil dead",
        "national lampoon",
        "monty python",
        "ocean",
        "naked gun",
        "scary movie",
        "hot shots",
        "planet of the apes",
        "the karate kid", "karate kid",
        "the chronicles of narnia", "narnia"
    ]
end function

' Unicode punctuation (the P categories) as far as titles need it: ASCII's
' and the common typographic marks. Not $ + < = > ^ ` | ~, which are symbols.
function NxClassifyIsPunct(ch as String) as Boolean
    if Instr(1, "!""#%&'()*,-./:;?@[\]_{}", ch) > 0 then return true
    code = Asc(ch)
    return code = 161 or code = 167 or code = 171 or code = 182 or code = 183 or code = 187 or code = 191 or (code >= 8208 and code <= 8231) or (code >= 8240 and code <= 8259)
end function

' trimmingCharacters(in: .punctuationCharacters).
function NxClassifyTrimPunct(s as String) as String
    first = 1
    last = s.Len()
    while first <= last and NxClassifyIsPunct(Mid(s, first, 1))
        first = first + 1
    end while
    while last >= first and NxClassifyIsPunct(Mid(s, last, 1))
        last = last - 1
    end while
    return Mid(s, first, last - first + 1)
end function

' hasRepeatingNames: a meaningful word (3+ letters, not a stop word) in
' max(3, 60% of the titles) titles, or a common title prefix of 4+
' characters that many titles start with.
function NxClassifyHasRepeatingNames(items as Object) as Boolean
    stopWords = {}
    for each w in ["the", "a", "an", "of", "and", "in", "on", "to", "for", "is", "it", "at", "by", "or", "as", "no", "not", "but", "be", "was", "with", "from"]
        stopWords[w] = true
    end for
    titles = []
    for each it in items
        titles.Push(NxFranchiseLower(NxToStr(it.title)))
    end for
    wordHits = {}
    wordHits.SetModeCaseSensitive()
    for each t in titles
        unique = {}
        unique.SetModeCaseSensitive()
        for each part in t.Split(" ")
            if part <> "" then
                word = NxClassifyTrimPunct(part)
                if word.Len() >= 3 and not stopWords.DoesExist(word) then unique[word] = true
            end if
        end for
        for each word in unique
            if wordHits[word] = invalid then wordHits[word] = 0
            wordHits[word] = wordHits[word] + 1
        end for
    end for
    threshold = (items.Count() * 6) \ 10
    if threshold < 3 then threshold = 3
    for each word in wordHits
        if wordHits[word] >= threshold then return true
    end for

    prefix = NxClassifyCommonPrefix(titles)
    if prefix <> invalid and prefix.Len() >= 4 then
        matches = 0
        for each t in titles
            if Left(t, prefix.Len()) = prefix then matches = matches + 1
        end for
        if matches >= threshold then return true
    end if
    return false
end function

' longestCommonPrefix, trimmed of spaces and punctuation; invalid when
' nothing is left.
function NxClassifyCommonPrefix(titles as Object) as Dynamic
    if titles.Count() = 0 then return invalid
    prefix = titles[0]
    for i = 1 to titles.Count() - 1
        s = titles[i]
        while prefix <> "" and Left(s, prefix.Len()) <> prefix
            prefix = Left(prefix, prefix.Len() - 1)
        end while
    end for
    ' .whitespaces.union(.punctuationCharacters) from both ends.
    first = 1
    last = prefix.Len()
    while first <= last and NxClassifyIsTrimmable(Mid(prefix, first, 1))
        first = first + 1
    end while
    while last >= first and NxClassifyIsTrimmable(Mid(prefix, last, 1))
        last = last - 1
    end while
    trimmed = Mid(prefix, first, last - first + 1)
    if trimmed = "" then return invalid
    return trimmed
end function

function NxClassifyIsTrimmable(ch as String) as Boolean
    if ch = " " or ch = Chr(9) or ch = Chr(160) then return true
    return NxClassifyIsPunct(ch)
end function

' nameAppearsInTitles: a name of 3+ characters inside 2 or more titles.
function NxClassifyNameInTitles(lowerName as String, items as Object) as Boolean
    if lowerName.Len() < 3 then return false
    hits = 0
    for each it in items
        if Instr(1, NxFranchiseLower(NxToStr(it.title)), lowerName) > 0 then hits = hits + 1
    end for
    return hits >= 2
end function
