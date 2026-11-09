#!/usr/bin/env node
/**
 * OPEN ON LAST CHANNEL (Trello I-017): the choice in scripts/nostalgex-last-channel.js, without a page.
 * A remembered channel is opened only when an enabled channel has the same id AND the same name;
 * every other case (renamed, renumbered, gone, package off, nothing kept, garbage kept) opens
 * nothing, so the guide falls back to the first enabled channel.
 *
 * Run: `npm run test:last-channel`. The page wiring is checked by
 * `npm run test:open-last-channel:browser`.
 */
import { strictEqual, deepStrictEqual } from "node:assert/strict";
import { readFileSync } from "node:fs";
import "./nostalgex-last-channel.js";

const LC = globalThis.NostalgexLastChannel;
let passed = 0;
const failures = [];
function check(label, fn) {
  try { fn(); passed += 1; } catch (e) { failures.push(`${label}: ${e.message}`); }
}

check("storage keys are the ones the page and Docker keep", () => {
  strictEqual(LC.OPEN_KEY, "nostalgex_open_last_channel");
  strictEqual(LC.CHANNEL_KEY, "nostalgex_last_channel");
});

check("off unless the stored value is exactly 1", () => {
  strictEqual(LC.isOn("1"), true);
  for (const v of ["0", "", "true", "on", " 1", "11", null, undefined, 1, true]) strictEqual(LC.isOn(v), false, String(v));
});

check("serialize keeps the id and the name, and parse reads them back", () => {
  deepStrictEqual(LC.parse(LC.serialize({ id: 12, name: "MTV 80S", number: 12, extra: "x" })), { id: 12, name: "MTV 80S" });
  deepStrictEqual(LC.parse(LC.serialize({ id: "franchise:abc", name: "STAR WARS" })), { id: "franchise:abc", name: "STAR WARS" });
});

check("serialize refuses a channel it could not match later", () => {
  for (const c of [null, undefined, {}, { id: 3 }, { name: "X" }, { id: "", name: "X" }, { id: 3, name: "" }, { id: null, name: "X" }, { id: 3, name: 7 }]) {
    strictEqual(LC.serialize(c), null, JSON.stringify(c));
  }
});

check("parse refuses anything serialize did not write", () => {
  for (const v of [null, undefined, "", "not json", "null", "[]", "[1,2]", "7", '"x"', "{}", '{"id":3}', '{"name":"X"}', '{"id":"","name":"X"}', '{"id":3,"name":""}', '{"id":3,"name":7}']) {
    strictEqual(LC.parse(v), null, String(v));
  }
});

const lineup = [
  { id: 1, name: "VHS VAULT" }, { id: 2, name: "DVD SHELF" }, { id: 12, name: "MTV 80S" }, { id: 40, name: "VHS VAULT" },
];
check("a channel with the same id and name is opened", () => {
  strictEqual(LC.channelToOpen({ id: 12, name: "MTV 80S" }, lineup), lineup[2]);
});
check("two channels with one name: the id picks the right one", () => {
  strictEqual(LC.channelToOpen({ id: 40, name: "VHS VAULT" }, lineup), lineup[3]);
  strictEqual(LC.channelToOpen({ id: 1, name: "VHS VAULT" }, lineup), lineup[0]);
});
check("an id kept as a string still finds a numeric id, and the other way round", () => {
  strictEqual(LC.channelToOpen({ id: "12", name: "MTV 80S" }, lineup), lineup[2]);
  strictEqual(LC.channelToOpen({ id: 7, name: "X" }, [{ id: "7", name: "X" }]).name, "X");
});
check("renamed: same id, other name, opens nothing", () => {
  strictEqual(LC.channelToOpen({ id: 12, name: "MTV 90S" }, lineup), null);
});
check("renumbered: the name now sits on another id, opens nothing", () => {
  strictEqual(LC.channelToOpen({ id: 13, name: "MTV 80S" }, lineup), null);
});
check("the name is matched exactly, not by case or spacing", () => {
  strictEqual(LC.channelToOpen({ id: 12, name: "mtv 80s" }, lineup), null);
  strictEqual(LC.channelToOpen({ id: 12, name: "MTV 80S " }, lineup), null);
});
check("a channel that is not in the enabled list (package off, dropped) opens nothing", () => {
  strictEqual(LC.channelToOpen({ id: 99, name: "GONE" }, lineup), null);
  strictEqual(LC.channelToOpen({ id: 12, name: "MTV 80S" }, lineup.filter((c) => c.id !== 12)), null);
  strictEqual(LC.channelToOpen({ id: 12, name: "MTV 80S" }, []), null);
});
check("nothing kept, or a bad list, opens nothing and never throws", () => {
  strictEqual(LC.channelToOpen(null, lineup), null);
  strictEqual(LC.channelToOpen(undefined, lineup), null);
  strictEqual(LC.channelToOpen({ id: 1, name: "VHS VAULT" }, null), null);
  strictEqual(LC.channelToOpen({ id: 1, name: "VHS VAULT" }, undefined), null);
  strictEqual(LC.channelToOpen({ id: 1, name: "VHS VAULT" }, [null, undefined, lineup[0]]), lineup[0]);
});

// The real lineup: every channel in channels.json finds itself and no other.
const stock = JSON.parse(readFileSync(new URL("../channels.json", import.meta.url), "utf8")).channels;
check("every stock channel is found by its own id and name, and by nothing else", () => {
  for (const ch of stock) {
    const saved = LC.parse(LC.serialize(ch));
    strictEqual(LC.channelToOpen(saved, stock), ch, `${ch.id} ${ch.name}`);
  }
});

if (failures.length) {
  console.error(`last-channel: ${failures.length} failed, ${passed} passed`);
  for (const f of failures) console.error("  " + f);
  process.exit(1);
}
console.log(`last-channel: ${passed} passed`);
