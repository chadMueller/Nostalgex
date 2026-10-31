#!/usr/bin/env node
/**
 * This repo is public. Its tests and docs used to carry addresses from the maintainer's
 * home subnet and the real names and ids of his own servers. This guard fails when any of
 * that comes back, in any tracked file.
 *
 * What it looks for:
 *   1. Home-network addresses, written either way: dotted, or dash-encoded as Plex's
 *      plex.direct hostnames write it. Held here only as SHA-256 hashes of their first
 *      three octets ("a.b.c"); every a.b.c.d in a line, in either form, is reduced to
 *      a.b.c and hashed. Use RFC 5737 addresses (192.0.2.x, 198.51.100.x, 203.0.113.x)
 *      or a generic 192.168.1.x in examples instead.
 *   2. Real server names and ids, held here only as SHA-256 hashes of the lowercase
 *      token, so this file does not publish them either. Every word-like token of a
 *      length in the list is hashed and compared.
 *
 * `PENDING` lists files known to still match, each waiting on its owner. The guard fails
 * on a match anywhere else, and also fails when a pending file comes back clean, so the
 * exception is removed the day it is fixed.
 *
 * Tracked files come from `git ls-files`, so build output and gitignored secrets are
 * never read. Run: `npm run test:leak-guard` (part of `npm test`); CI runs it on every
 * pull request, whatever the change touches.
 */
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

// sha256("a.b.c") of each home-network /24.
const HASHED_PREFIXES = new Set([
  "605c8dd8f8651179c590020dd44049691b9f601aa29557ee9715c22dea9e2a3e",
  "22aede7927e7c47252dee440239deca84cf9ccc2ac59978686d81357ebe22d9a",
  "5c94778b32e67b79bb89d4cc2f2ca19a33db3260f0020b3474b4f2f258a8c624",
  "c0ad23c09e4e78aabe9bf6eadd2952006a0e5e50356ddbd5047a26e8cb53b981",
]);

// An address in a line, dotted (a.b.c.d) or dash-encoded (a-b-c-d), one separator
// throughout. A lookahead, so overlapping runs of numbers are all tried.
const ADDRESS_RE = /(?=(?<!\d)(\d{1,3})([.-])(\d{1,3})\2(\d{1,3})\2\d)/g;

// sha256(lowercase token) -> what it was, in words.
const HASHED_TOKENS = new Map([
  ["9aac05d03dc905d1b1a18bed0f03c19e65bf7b7279060592aa22e8c94585540e", "a real Emby server name"],
  ["61f45fcd0d1272242e9f42b77016a01e82d1da7e7b5a18952865fb45b14e6a68", "a real Emby server id"],
  ["d8c74467c29f63a419299dbf6d83c676a8e44f5363d3b08e0681f1b0e6403ac8", "a real Plex machine identifier"],
  ["f612f76efe28a52c8e93d4bf67a59ea005faf23c5bbae1ee09924c2e8aea8e1d", "a real plex.direct certificate hash"],
]);
const TOKEN_LENGTHS = new Set([15, 32, 40]);

// path -> who fixes it. Files listed here still match and are waiting on their owner.
const PENDING = new Map([]);

const sha256 = (s) => createHash("sha256").update(s).digest("hex");

/** Whether a line holds an address whose a.b.c hashes into `prefixes`. */
function hasAddressIn(line, prefixes) {
  for (const m of line.matchAll(ADDRESS_RE)) {
    if (prefixes.has(sha256(`${m[1]}.${m[3]}.${m[4]}`))) return true;
  }
  return false;
}

/**
 * Every finding in one file's text, as short descriptions (never the matched text).
 * `prefixes` is for the self-test, which checks the matching with a made-up network.
 */
export function findingsIn(text, prefixes = HASHED_PREFIXES) {
  const found = [];
  const lines = text.split("\n");
  lines.forEach((line, i) => {
    if (hasAddressIn(line, prefixes)) found.push(`line ${i + 1}: a home-network address`);
    for (const token of line.match(/[A-Za-z0-9][A-Za-z0-9-]*/g) || []) {
      // Hyphenated tokens are checked whole and in parts: a hostname is one token, a
      // hex id can sit inside a dash-joined plex.direct label.
      const candidates = token.includes("-") ? [token, ...token.split("-")] : [token];
      for (const c of candidates) {
        if (!TOKEN_LENGTHS.has(c.length)) continue;
        const what = HASHED_TOKENS.get(sha256(c.toLowerCase()));
        if (what) found.push(`line ${i + 1}: ${what}`);
      }
    }
  });
  return found;
}

function trackedFiles() {
  return execFileSync("git", ["ls-files", "-z"], { cwd: root, encoding: "utf8", maxBuffer: 64 << 20 })
    .split("\0")
    .filter(Boolean);
}

function readText(path) {
  let buf;
  try {
    buf = readFileSync(join(root, path));
  } catch {
    return null; // deleted in the working tree, or a submodule
  }
  if (buf.includes(0)) return null; // binary
  return buf.toString("utf8");
}

function selfTest() {
  const check = (cond, msg) => { if (!cond) throw new Error(`self-test: ${msg}`); };
  // The matching itself, against a made-up network (10.20.30.x) hashed the same way.
  const madeUp = new Set([sha256("10.20.30")]);
  check(findingsIn("http://10.20.30.7:8096", madeUp).length === 1, "missed a dotted address");
  check(findingsIn("https://10-20-30-79.abc.plex.direct", madeUp).length === 1, "missed a dash-encoded address");
  check(findingsIn("see 1.10.20.30.7 and x10.20.30.9", madeUp).length === 1, "missed an address inside a longer run");
  check(findingsIn("http://10.20.31.7 10-20-30 10.20.30", madeUp).length === 0, "flagged a near miss or a bare prefix");
  check(findingsIn("10.20-30.7", madeUp).length === 0, "flagged mixed separators");
  // The real list: examples and a common home range are not flagged.
  check(findingsIn("http://192.0.2.7:8096 192.168.1.10 192-168-1-79 192-0-2-79").length === 0, "flagged an example address");
  check(findingsIn("Attic-Server 0123456789abcdef0123456789abcdef").length === 0, "flagged a made-up name");
  // One real address, when the maintainer provides it (never stored in the repo).
  const sample = process.env.NOSTALGEX_LEAK_GUARD_SAMPLE;
  if (sample) {
    check(findingsIn(`http://${sample}:8096`).length === 1, "missed NOSTALGEX_LEAK_GUARD_SAMPLE, dotted");
    check(findingsIn(`https://${sample.replaceAll(".", "-")}.abc.plex.direct`).length === 1, "missed NOSTALGEX_LEAK_GUARD_SAMPLE, dash-encoded");
  }
}

function main() {
  selfTest();
  const failures = [];
  const pendingSeen = new Set();
  let scanned = 0;
  for (const path of trackedFiles()) {
    const text = readText(path);
    if (text == null) continue;
    scanned += 1;
    const found = findingsIn(text);
    if (found.length === 0) continue;
    if (PENDING.has(path)) {
      pendingSeen.add(path);
      continue;
    }
    for (const f of found) failures.push(`${path} ${f}`);
  }
  for (const [path, owner] of PENDING) {
    if (!pendingSeen.has(path)) {
      failures.push(`${path} is clean now: remove it from PENDING in scripts/public-repo-leak-guard.mjs (${owner})`);
    }
  }
  if (failures.length) {
    console.error("public-repo-leak-guard: home-network details in tracked files:");
    for (const f of failures) console.error(`  ${f}`);
    console.error("Use 192.0.2.x (RFC 5737) or 192.168.1.x and made-up server names instead.");
    process.exit(1);
  }
  const pending = [...pendingSeen].map((p) => `${p} (${PENDING.get(p)})`).join("; ");
  console.log(`public-repo-leak-guard: ${scanned} tracked files clean${pending ? `; pending: ${pending}` : ""}`);
}

main();
