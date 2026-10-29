import Foundation

extension ChannelRules {
    /// Lossless encoding for library snapshots (mirrors `ChannelRulesJSON`).
    func toChannelRulesJSON() -> ChannelRulesJSON {
        ChannelRulesJSON(
            type: type?.rawValue,
            source: source?.rawValue,
            genres: genres.map {
                GenreRulesJSON(include: $0.include, requireAll: $0.requireAll, exclude: $0.exclude)
            },
            studios: studios,
            yearRange: yearRange.map { YearRangeJSON(min: $0.min, max: $0.max) },
            contentRatings: contentRatings,
            allowUnrated: allowUnrated,
            ratingMin: ratingMin,
            durationRange: durationRange.map {
                DurationRangeJSON(min: $0.min, max: $0.max)
            },
            watchedOnly: watchedOnly,
            unwatchedOnly: unwatchedOnly,
            rewatched: rewatched,
            titleContains: titleContains,
            episodeTitleContains: episodeTitleContains,
            episodeSummaryContains: episodeSummaryContains,
            episodeSeasonalTitleContains: episodeSeasonalTitleContains,
            episodeAirWindow: episodeAirWindow.map { AirWindowJSON(from: $0.from, to: $0.to) },
            episodeTitleExcludes: episodeTitleExcludes,
            matchTmdbGenres: matchTmdbGenres ? true : nil,
            titleExcludes: titleExcludes,
            editorialOverrides: editorialOverrides,
            addedWithinDays: addedWithinDays,
            releasedWithinMonths: releasedWithinMonths,
            keywords: keywords,
            keywordsRequireAll: keywordsRequireAll,
            keywordsExclude: keywordsExclude,
            keywordsRequireAnyGenre: keywordsRequireAnyGenre,
            keywordGatedGenres: keywordGatedGenres,
            networks: networks,
            productionCompanies: productionCompanies,
            imdbRatingMin: imdbRatingMin,
            imdbVotesMin: imdbVotesMin,
            rtScoreMin: rtScoreMin,
            metacriticMin: metacriticMin,
            wonOscar: wonOscar,
            manifestOnly: manifestOnly,
            manifestOnlyGenreFallback: manifestOnlyGenreFallback
        )
    }
}

extension TimeRestrictions {
    func toTimeRestrictionsJSON() -> TimeRestrictionsJSON {
        TimeRestrictionsJSON(
            blockRatings: blockRatings.map {
                BlockRatingsJSON(ratings: $0.ratings, blockBefore: $0.blockBefore, blockAfter: $0.blockAfter)
            },
            tvOnlyBefore: tvOnlyBefore,
            onlyAfterHour: onlyAfterHour
        )
    }
}

extension ExclusiveRule {
    func toExclusiveRuleJSON() -> ExclusiveRuleJSON {
        ExclusiveRuleJSON(
            channelID: channelIDs.count == 1 ? channelIDs.first : nil,
            channelIDs: channelIDs.count == 1 ? nil : channelIDs,
            genres: genres.isEmpty ? nil : genres,
            titleContains: titleContains.isEmpty ? nil : titleContains,
            editorialTitles: editorialTitles.isEmpty ? nil : editorialTitles,
            manifestExclusive: manifestExclusive ? true : nil,
            type: type?.rawValue,
            source: source?.rawValue
        )
    }
}
