// The web tuner's enrichment (scripts/nostalgex-enrichment.js) run over the fixture documents
// the Roku port also tests against (roku/tests/gen-enrichment.mjs), written out for
// EnrichmentVectorTest. The Kotlin parsers, row mapping, OMDb gates and quota clock have to
// answer exactly as the web tuner's. Run by the engine's `genEnrichmentVectors` task before its tests.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../../..");
const out = process.argv[2];
if (!out) throw new Error("usage: gen-enrichment-vectors.mjs <out.json>");

const { enrichmentVectors } = await import(resolve(repoRoot, "roku/tests/gen-enrichment.mjs"));
const vectors = enrichmentVectors(repoRoot);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(vectors, null, 1));
console.log(`enrichment vectors: ${vectors.tmdb.length} TMDB, ${vectors.omdb.length} OMDb, ${vectors.rows.length} rows, ${vectors.candidates.length} candidates`);
