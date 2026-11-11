// The web tuner's watch state (scripts/nostalgex-watch-state.js) over the Roku port's scripts
// (roku/tests/gen-watch.mjs): the pulse backoff's answers and the cleanup plans for priors the
// golden file doesn't hold. Run by the engine's `genWatchVectors` task before its tests.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../../..");
const out = process.argv[2];
if (!out) throw new Error("usage: gen-watch-vectors.mjs <out.json>");
const { watchVectors } = await import(resolve(repoRoot, "roku/tests/gen-watch.mjs"));
const vectors = await watchVectors(repoRoot);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(vectors, null, 1));
console.log(`watch vectors: ${vectors.backoff.length} backoff scripts, ${vectors.plans.length} plans`);
