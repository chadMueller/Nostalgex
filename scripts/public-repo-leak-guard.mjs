#!/usr/bin/env node
/**
 * This repo is public. Its tests and docs used to carry the maintainer's home network
 * (a 192.168.4.x subnet) and the real names and ids of his own servers. This guard fails
 * when any of that comes back, in any tracked file.
 *
 * What it looks for:
 *   1. The home subnet, written either way: dotted, or dash-encoded as Plex's plex.direct
 *      hostnames write it. Use RFC 5737 addresses (192.0.2.x, 198.51.100.x, 203.0.113.x)
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

// Built from parts so this file does not match itself.
const subnet = ["192", "168", "4"];
const ADDRESS_PATTERNS = [
  new RegExp(subnet.join("\\.") + "\\.\\d"),
  new RegExp(subnet.join("-") + "-\\d"),
];

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

/** Every finding in one file's text, as short descriptions (never the matched text). */
export function findingsIn(text) {
  const found = [];
  const lines = text.split("\n");
  lines.forEach((line, i) => {
    for (const re of ADDRESS_PATTERNS) {
      if (re.test(line)) found.push(`line ${i + 1}: the home subnet`);
    }
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
  const dotted = subnet.join(".") + ".7";
  const dashed = subnet.join("-") + "-7";
  const check = (cond, msg) => { if (!cond) throw new Error(`self-test: ${msg}`); };
  check(findingsIn(`http://${dotted}:8096`).length === 1, "missed a dotted home address");
  check(findingsIn(`https://${dashed}.abc.plex.direct`).length === 1, "missed a dash-encoded home address");
  check(findingsIn("http://192.0.2.7:8096 192.168.1.10 192-0-2-79").length === 0, "flagged an example address");
  check(findingsIn("Attic-Server 0123456789abcdef0123456789abcdef").length === 0, "flagged a made-up name");
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
