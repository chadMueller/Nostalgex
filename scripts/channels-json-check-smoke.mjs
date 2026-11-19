#!/usr/bin/env node
/**
 * The channels.json gate (scripts/channels-json-check.mjs) catches what it is for: each bad copy below is the real file with
 * one thing wrong, and each must fail with a message that says what. The real file, with the real loaders, must pass.
 * Offline: the deployed copy is a stand-in. Run: `npm run test:channels-json`.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import assert from "node:assert/strict";

const repo = fileURLToPath(new URL("../", import.meta.url));
const real = JSON.parse(readFileSync(join(repo, "channels.json"), "utf8"));
const { validateChannels } = await import("./channels-json-check.mjs");

// The loaders, as the script reads them (its own reader runs in the real check below).
const run = (doc, opts = {}) => validateChannels(doc, { previous: { version: real.version }, ...opts });
const copy = () => structuredClone(real);
let passed = 0;
const ok = (label, fn) => { fn(); passed += 1; };
const mustFail = (label, doc, pattern, opts) => ok(label, () => {
  const problems = run(doc, opts);
  assert.ok(problems.some((p) => pattern.test(p)), `${label}: wanted ${pattern}, got ${JSON.stringify(problems)}`);
});

ok("the real file passes, with the real loaders (the script as CI runs it)", () => {
  const out = execFileSync("node", [join(repo, "scripts/channels-json-check.mjs")], { encoding: "utf8", env: { ...process.env, NX_CHANNELS_PREVIOUS: join(repo, "channels.json") } });
  assert.match(out, /every rule key known to Swift, JS, Roku and Android/);
});
ok("the real file has a version and passes with no loaders and no deployed copy", () => assert.deepEqual(validateChannels(real, {}), []));

let d = copy(); delete d.channels[3].name;
mustFail("a channel with no name", d, /missing "name"/);
d = copy(); d.channels[5].minItems = "5";
mustFail("minItems that is not a number", d, /"minItems" should be a integer/);
d = copy(); d.channels[2].colorHex = "red";
mustFail("a colour that is not #RRGGBB", d, /colour/);
d = copy(); d.channels[9].id = d.channels[8].id;
mustFail("a repeated id", d, /id \d+ is also used by/);
d = copy(); d.channels[9].number = d.channels[8].number;
mustFail("a repeated number", d, /number \d+ is also used by/);
// id and number are checked separately: a channel whose id is another's number is fine.
ok("an id that equals another channel's number is allowed", () => {
  const c = copy();
  const a = c.channels.find((x) => x.id !== x.number);
  const other = c.channels.find((x) => x !== a && x.number !== a.id && x.id !== a.number);
  assert.ok(a && other);
  assert.deepEqual(run(c).filter((p) => /also used by/.test(p)), []);
});
d = copy(); d.channels[4].rules.madeUpRule = true;
mustFail("a rule key no loader knows", d, /rule key "madeUpRule".*Swift, JS, Roku, Android loaders/, { loaderText: loaders() });
function loaders() {
  // Reuse the script's own reader by running it against a doc is not possible here; read the four filters the same way.
  const read = (f) => readFileSync(join(repo, f), "utf8");
  return {
    files: {
      "Nostalgex/Nostalgex/Models/Channel.swift": read("Nostalgex/Nostalgex/Models/Channel.swift"),
      "scripts/nostalgex-channel-filter.cjs": read("scripts/nostalgex-channel-filter.cjs"),
      "roku/source/filter/ChannelFilter.brs": read("roku/source/filter/ChannelFilter.brs"),
      "android/engine/src/main/kotlin/com/muellhaus/nostalgex/engine/ChannelFilter.kt": read("android/engine/src/main/kotlin/com/muellhaus/nostalgex/engine/ChannelFilter.kt"),
    },
    sources: { Swift: [], JS: [], Roku: [], Android: [] },
  };
}
ok("a rule key one loader lacks is named with that loader", () => {
  const l = loaders();
  l.files["roku/source/filter/ChannelFilter.brs"] = l.files["roku/source/filter/ChannelFilter.brs"].replaceAll("yearRange", "yr");
  const problems = run(real, { loaderText: l });
  assert.ok(problems.some((p) => /rule key "yearRange".*Roku loader: it would be ignored/.test(p)), JSON.stringify(problems));
});
d = copy(); d.bundles[0].channelIDs.push(99999);
mustFail("a bundle holding a channel that does not exist", d, /99999, which is not a channel id/);
d = copy(); d.channels[0].category = "nope";
mustFail("a category that is not a bundle", d, /category "nope" is not a bundle id/);
d = copy(); d.version = real.version - 1;
mustFail("a version lower than the deployed copy", d, /version \d+ is lower than the deployed copy's/);
d = copy(); d.version = "50";
mustFail("a version that is not a number", d, /version must be a whole number/);
ok("the same version, or a higher one, is fine", () => { assert.deepEqual(run(real), []); const c = copy(); c.version += 1; assert.deepEqual(run(c), []); });
d = copy(); d.formatVersion = 2;
mustFail("formatVersion above 1", d, /formatVersion is 2.*read up to 1/);
d = copy(); d.formatVersion = 0;
mustFail("formatVersion 0", d, /formatVersion must be a whole number from 1 up/);
ok("formatVersion 1 is fine, and so is none", () => { const c = copy(); c.formatVersion = 1; assert.deepEqual(run(c), []); assert.deepEqual(run(real), []); });
mustFail("CI without the deployed copy", real, /deployed copy could not be read/, { previous: null, previousError: "offline", requirePrevious: true });
ok("a laptop without the deployed copy is not blocked", () => assert.deepEqual(validateChannels(real, { previous: null, previousError: "offline", requirePrevious: false }), []));
ok("not an object, not a list", () => {
  assert.ok(validateChannels([], {}).length);
  assert.ok(validateChannels({ version: 1, bundles: [], channels: [] }, {}).length);
});

console.log(`channels-json check smoke: ${passed} checks passed`);
