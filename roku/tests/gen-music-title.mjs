// Music video title vectors for MusicTitleGoldenTests.brs (issue #239, N-034):
// what the web tuner's own module (scripts/nostalgex-music-brainz.js, cleanTitle
// and parseTitle) answers for every input in scripts/music-title-golden.json.
// The golden file gives a parse for 8 of its inputs; this gives one for all of
// them, and fails here, before any BrightScript runs, if the module and the
// golden file's `clean` cases disagree.
import { readFileSync } from "node:fs";
import { join } from "node:path";

export function musicTitleVectors(upstream) {
  const scope = {};
  new Function("globalThis", "window", readFileSync(join(upstream, "scripts", "nostalgex-music-brainz.js"), "utf8"))(scope, scope);
  const MB = scope.NostalgexMusicBrainz;
  if (!MB || typeof MB.cleanTitle !== "function" || typeof MB.parseTitle !== "function") {
    throw new Error("upstream nostalgex-music-brainz.js changed shape: no cleanTitle or parseTitle");
  }
  const golden = JSON.parse(readFileSync(join(upstream, "scripts", "music-title-golden.json"), "utf8"));
  for (const c of golden.clean) {
    if (MB.cleanTitle(c.in) !== c.out) throw new Error(`music-title-golden.json and cleanTitle disagree on ${JSON.stringify(c.in)}`);
  }
  const inputs = [...new Set([...golden.clean, ...golden.parse].map((c) => c.in))];
  return {
    titles: inputs.map((raw) => {
      const p = MB.parseTitle(raw);
      return { in: raw, clean: MB.cleanTitle(raw), artist: p.artist ?? null, song: p.song };
    }),
  };
}
