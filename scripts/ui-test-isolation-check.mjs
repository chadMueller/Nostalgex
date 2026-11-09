#!/usr/bin/env node
/**
 * Apple TV UI tests must never reach a real Apple TV's stores.
 *
 * On 2026-11-09 a UI test launched the app with `-uiTestResetCredentials` and no harness root on a real Apple TV, and the
 * flag deleted that TV's library snapshot, rewrote its settings and removed its sign-in. `TEST_RUNNER_NOSTALGEX_HARNESS_ROOT`
 * only reaches the test runner, not the app a test launches, so a test is isolated only if it sets
 * `NOSTALGEX_HARNESS_ROOT` on the app's own `launchEnvironment`. `NostalgexUITests/IsolatedApp.swift` does that in one place
 * (`isolatedApp(...)`), and this check holds every other test file to it.
 *
 * Fails when:
 *   1. a file in NostalgexUITests other than IsolatedApp.swift calls `XCUIApplication(` (a test made its own app, and can
 *      forget the root);
 *   2. a file names a launch flag that deletes or rewrites stored data and does not make its app through
 *      `isolatedApp(` (or sets `NOSTALGEX_HARNESS_ROOT` itself);
 *   3. a file passes such a flag to `realStoresApp(` (the app ignores it there), or gives `realStoresApp` no reason;
 *   4. IsolatedApp.swift stops setting NOSTALGEX_HARNESS_ROOT, or its list of those flags differs from the app's
 *      `TestLaunchFlags.destructive`, the single list the app honours only under isolation.
 *
 * No dependencies: `node scripts/ui-test-isolation-check.mjs`. Part of `npm test`; CI runs it on every pull request.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const uiDir = path.join(root, 'Nostalgex/NostalgexUITests');
const appFlags = path.join(root, 'Nostalgex/Nostalgex/Services/TestLaunchFlags.swift');
const helperName = 'IsolatedApp.swift';

const problems = [];
const fail = (where, what) => problems.push(`${where}: ${what}`);

/** Code only: comments and string contents out of the way of the regexes below, but string text kept for flag names. */
function withoutComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' ')).replace(/\/\/.*$/gm, '');
}

/** The quoted flags inside `<name> ... = [ ... ]` or `Set<String> = [ ... ]` of a Swift list. */
function flagsOf(source, listName) {
  const code = withoutComments(source);
  const start = new RegExp(`\\b${listName}\\b[^=]*=\\s*\\[`).exec(code);
  if (!start) return null;
  const open = start.index + start[0].length;
  const close = code.indexOf(']', open);
  return [...code.slice(open, close).matchAll(/"(-[A-Za-z0-9]+)"/g)].map((m) => m[1]);
}

const appSource = fs.readFileSync(appFlags, 'utf8');
const destructive = flagsOf(appSource, 'destructive');
if (!destructive || destructive.length === 0) {
  console.error(`Cannot read TestLaunchFlags.destructive from ${path.relative(root, appFlags)}`);
  process.exit(2);
}

const files = fs.readdirSync(uiDir).filter((f) => f.endsWith('.swift')).sort();
if (!files.includes(helperName)) {
  console.error(`${helperName} is missing from ${path.relative(root, uiDir)}`);
  process.exit(2);
}

for (const file of files) {
  const text = withoutComments(fs.readFileSync(path.join(uiDir, file), 'utf8'));
  const where = `NostalgexUITests/${file}`;

  if (file === helperName) {
    if (!/launchEnvironment\[\s*IsolatedAppRoots\.environmentKey\s*\]\s*=/.test(text)
      || !/environmentKey\s*=\s*"NOSTALGEX_HARNESS_ROOT"/.test(text)) {
      fail(where, 'isolatedApp no longer sets NOSTALGEX_HARNESS_ROOT on launchEnvironment');
    }
    const mirrored = flagsOf(fs.readFileSync(path.join(uiDir, file), 'utf8'), 'destructiveFlags') || [];
    const missing = destructive.filter((f) => !mirrored.includes(f));
    const extra = mirrored.filter((f) => !destructive.includes(f));
    if (missing.length || extra.length) {
      fail(where, `destructiveFlags differs from TestLaunchFlags.destructive (missing: ${missing.join(', ') || 'none'}; extra: ${extra.join(', ') || 'none'})`);
    }
    continue;
  }

  const makesOwnApp = [...text.matchAll(/\bXCUIApplication\s*\(/g)];
  for (const m of makesOwnApp) {
    const line = text.slice(0, m.index).split('\n').length;
    fail(`${where}:${line}`, 'calls XCUIApplication( directly; make the app with isolatedApp(...) so NOSTALGEX_HARNESS_ROOT is always set');
  }

  const usesDestructive = destructive.filter((f) => text.includes(`"${f}"`));
  const isolated = /\bisolatedApp\s*\(/.test(text) || /launchEnvironment\[\s*"NOSTALGEX_HARNESS_ROOT"\s*\]\s*=/.test(text);
  if (usesDestructive.length && !isolated) {
    fail(where, `passes ${usesDestructive.join(', ')} (deletes or rewrites stored data) without NOSTALGEX_HARNESS_ROOT; use isolatedApp(...)`);
  }

  for (const m of text.matchAll(/\brealStoresApp\s*\(([\s\S]*?)\)\s*$/gm)) {
    const args = m[1];
    const line = text.slice(0, m.index).split('\n').length;
    const named = destructive.filter((f) => args.includes(`"${f}"`));
    if (named.length) fail(`${where}:${line}`, `realStoresApp is given ${named.join(', ')}; the app ignores it without NOSTALGEX_HARNESS_ROOT`);
    if (!/because:\s*"\s*[^"\s][^"]*"/.test(args)) fail(`${where}:${line}`, 'realStoresApp needs because: "why this test cannot be isolated"');
  }
}

if (problems.length) {
  console.error('UI test isolation check FAILED:\n  ' + problems.join('\n  '));
  console.error('\nSee Nostalgex/NostalgexUITests/IsolatedApp.swift. A test that must see the real stores uses realStoresApp(because:), which runs on the simulator only.');
  process.exit(1);
}
console.log(`UI test isolation ok: ${files.length - 1} test files, every app made through isolatedApp; ${destructive.length} destructive launch flags mirrored.`);
