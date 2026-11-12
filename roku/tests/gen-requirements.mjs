// Vectors for ChannelsMissingTests.brs (issue #280, #228): what the web tuner's own module
// (scripts/nostalgex-channel-requirements.js, a port of the Apple TV's ChannelRules.plainLanguageRequirements)
// answers. The plain-words lines per channel are scripts/channel-requirements-golden.json, copied byte for byte
// by gen-vectors.mjs; this adds the page's amber line, "Needs 15 matching titles. You have 3.", for a set of
// (minItems, matched) pairs, and checks here, before any BrightScript runs, that the module and the golden file
// agree on every channel in channels.json.
import { readFileSync } from "node:fs";
import { join } from "node:path";

export function requirementsVectors(upstream) {
  const scope = {};
  new Function("globalThis", "window", readFileSync(join(upstream, "scripts", "nostalgex-channel-requirements.js"), "utf8"))(scope, scope);
  const R = scope.NostalgexChannelRequirements;
  if (!R || typeof R.plainRequirements !== "function" || typeof R.needsLine !== "function") {
    throw new Error("upstream nostalgex-channel-requirements.js changed shape: no plainRequirements or needsLine");
  }
  const golden = JSON.parse(readFileSync(join(upstream, "scripts", "channel-requirements-golden.json"), "utf8"));
  const config = JSON.parse(readFileSync(join(upstream, "channels.json"), "utf8"));
  for (const ch of config.channels) {
    const want = golden.channels[String(ch.id)];
    if (!want) throw new Error(`channel-requirements-golden.json has no channel ${ch.id}; run UPDATE_GOLDEN=1 npm test`);
    if (JSON.stringify(R.plainRequirements(ch.rules)) !== JSON.stringify(want)) {
      throw new Error(`channel-requirements-golden.json and plainRequirements disagree on channel ${ch.id}`);
    }
  }
  const mins = [1, 2, 5, 15, 50, 250];
  const matched = [null, 0, 1, 3, 1234];
  const needs = [];
  for (const minItems of mins) for (const m of matched) needs.push({ minItems, matched: m, line: R.needsLine(minItems, m) });
  return { needs };
}
