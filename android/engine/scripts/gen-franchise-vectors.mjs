// The web tuner's franchise builder (scripts/nostalgex-franchise-builder.js) run over the
// text edge cases and libraries the Roku port also tests against (roku/tests/gen-franchise.mjs),
// written out for FranchiseVectorTest. The Kotlin port has to key, match, name and sort
// exactly as the web tuner does. Run by the engine's `genFranchiseVectors` task before its tests.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../../..");
const out = process.argv[2];
if (!out) throw new Error("usage: gen-franchise-vectors.mjs <out.json>");

const { franchiseVectors } = await import(resolve(repoRoot, "roku/tests/gen-franchise.mjs"));
const vectors = franchiseVectors(repoRoot);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(vectors, null, 1));
console.log(`franchise vectors: ${vectors.text.length} titles, ${vectors.tokens.length} tokens, ${vectors.names.length} names, ${vectors.cases.length} cases, ${vectors.collectionFolds.length} folds`);
