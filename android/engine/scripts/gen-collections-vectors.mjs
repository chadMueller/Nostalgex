// The web tuner's server collections (scripts/nostalgex-collections.js) run over the fixtures
// the Roku port also tests against (roku/tests/gen-collections.mjs), written out for
// CollectionsVectorTest. The Kotlin name cleaning, stock matching, manifest overlap, member
// index, candidates, folds, numbering and the Plex and BoxSet calls have to answer exactly as
// the web tuner's. Run by the engine's `genCollectionsVectors` task before its tests.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../../..");
const out = process.argv[2];
if (!out) throw new Error("usage: gen-collections-vectors.mjs <out.json>");

const { collectionsVectors } = await import(resolve(repoRoot, "roku/tests/gen-collections.mjs"));
const vectors = await collectionsVectors(repoRoot);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(vectors, null, 1));
console.log(
  `collections vectors: ${vectors.text.length} titles, ${vectors.match.length} matches, ` +
    `${vectors.overlap.length} overlaps, ${vectors.candidates.length} candidate runs, ` +
    `${vectors.plex.length} Plex, ${vectors.boxSets.length} BoxSet`,
);
