// What a channel asks of the library, in plain words, for WHY ARE SOME CHANNELS MISSING?
//
// PARITY with tvOS and Roku
//   Nostalgex/Nostalgex/Models/Channel.swift                        ChannelRules.plainLanguageRequirements
//   Nostalgex/Nostalgex/Views/Settings/SharedComponents (Requirement card)  the "Needs n matching titles" line
//   Roku: source/guide/ChannelsMissing.brs (#227, #228)
// The lines for every channel in channels.json are in scripts/channel-requirements-golden.json; a port should return the same
// text for the same rules. Only the fields a viewer can read without knowing what Plex, TMDB or OMDb are.
(function (global) {
  'use strict';

  /** The rules of one channel (a channels.json `rules` object) as short plain lines. Never empty. */
  function plainRequirements(rules) {
    const r = rules || {};
    const lines = [];
    if (r.type === 'movie') lines.push('Movies only');
    else if (r.type === 'episode') lines.push('TV episodes only');
    if (r.source === 'musicVideo') lines.push('Music videos only');

    const g = r.genres;
    if (g) {
      if ((g.include || []).length) lines.push(`Genre: ${g.include.join(' or ')}`);
      if ((g.requireAll || []).length) lines.push(`Needs every one of these genres: ${g.requireAll.join(', ')}`);
      if ((g.exclude || []).length) lines.push(`Not genre: ${g.exclude.join(', ')}`);
    }
    if ((r.studios || []).length) lines.push(`Studio: ${r.studios.join(' or ')}`);
    if ((r.networks || []).length) lines.push(`Network: ${r.networks.join(' or ')}`);

    const y = r.yearRange;
    if (y) {
      const lo = y.min != null, hi = y.max != null;
      if (lo && hi) lines.push(`Released ${y.min} to ${y.max}`);
      else if (lo) lines.push(`Released ${y.min} or later`);
      else if (hi) lines.push(`Released before ${y.max}`);
    }
    if ((r.contentRatings || []).length) lines.push(`Rated: ${r.contentRatings.join(', ')}`);
    if (r.ratingMin != null) lines.push(`Plex star rating ${Number(r.ratingMin).toFixed(1)} or higher`);
    if (r.imdbRatingMin != null) lines.push(`IMDb rating ${Number(r.imdbRatingMin).toFixed(1)} or higher`);
    if (r.rtScoreMin != null) lines.push(`Rotten Tomatoes score ${r.rtScoreMin} or higher`);
    if (r.metacriticMin != null) lines.push(`Metacritic score ${r.metacriticMin} or higher`);
    if (r.wonOscar) lines.push('Won an Oscar');
    if (r.watchedOnly) lines.push('Already watched titles only');
    if (r.unwatchedOnly) lines.push('Unwatched titles only');
    if (r.rewatched) lines.push('Watched three times or more');
    if ((r.keywords || []).length) lines.push(`About: ${r.keywords.slice(0, 4).join(', ')}`);

    const d = r.durationRange;
    if (d) {
      const lo = d.min != null, hi = d.max != null;
      if (lo && hi) lines.push(`Runs ${d.min} to ${d.max} minutes`);
      else if (lo) lines.push(`Runs ${d.min} minutes or longer`);
      else if (hi) lines.push(`Runs ${d.max} minutes or shorter`);
    }
    if (lines.length === 0) lines.push('A specific, curated list of titles rather than a general rule');
    return lines;
  }

  /** "Needs 15 matching titles. You have 3." (`matched` null while counting.) */
  function needsLine(minItems, matched) {
    const need = `Needs ${minItems} matching title${minItems === 1 ? '' : 's'}.`;
    return matched == null ? `${need} Counting yours…` : `${need} You have ${matched}.`;
  }

  const api = { plainRequirements, needsLine };
  global.NostalgexChannelRequirements = api;
  if (typeof module !== 'undefined' && typeof module.exports !== 'undefined') module.exports = api;
})(typeof window !== 'undefined' ? window : globalThis);
