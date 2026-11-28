#!/usr/bin/env node
// Writes the weather channel's pixel icons as PNGs: images/weather/<icon>-<size>.png, 18 icons at the
// three sizes the screens draw them (336, 192 and 168), each cell a whole number of pixels so the Roku
// scales nothing. The icons are the web tuner's: scripts/nostalgex-weather-screens.js draws them from
// 24 by 24 letter grids (ICON_GRIDS), and this reads the same grids.
//
//   node tests/gen-weather-assets.mjs <path to nostalgex-weather-screens.js>
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import vm from "node:vm";
import { deflateSync } from "node:zlib";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const src = process.argv[2];
if (!src) { console.error("usage: node tests/gen-weather-assets.mjs <nostalgex-weather-screens.js>"); process.exit(2); }
// The file is a browser script: run it in a bare context and read what it puts on the global.
const ctx = vm.createContext({});
vm.runInContext(readFileSync(resolve(src), "utf8"), ctx);
const screens = ctx.NostalgexWeatherScreens;
const outDir = fileURLToPath(new URL("../images/weather/", import.meta.url));
mkdirSync(outDir, { recursive: true });

const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc = (buf) => { let c = 0xffffffff; for (const b of buf) c = crcTable[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type), data]);
  const sum = Buffer.alloc(4); sum.writeUInt32BE(crc(body));
  return Buffer.concat([len, body, sum]);
}
function png(w, h, rgba) {
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 4 + 1)] = 0; rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4); }
  const head = Buffer.alloc(13); head.writeUInt32BE(w, 0); head.writeUInt32BE(h, 4); head[8] = 8; head[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", head), chunk("IDAT", deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0))]);
}

let n = 0;
for (const [name, grid] of Object.entries(screens.ICON_GRIDS)) {
  for (const size of [288, 168, 144]) {
    const cell = size / 24;
    const px = Buffer.alloc(size * size * 4);
    for (let r = 0; r < 24; r++) for (let c = 0; c < 24; c++) {
      const ch = grid[r][c];
      if (ch === ".") continue;
      const hex = screens.ICON_COLORS[ch];
      const rgb = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
      for (let y = r * cell; y < (r + 1) * cell; y++) for (let x = c * cell; x < (c + 1) * cell; x++) {
        const o = (y * size + x) * 4; px[o] = rgb[0]; px[o + 1] = rgb[1]; px[o + 2] = rgb[2]; px[o + 3] = 255;
      }
    }
    writeFileSync(`${outDir}${name}-${size}.png`, png(size, size, px));
    n++;
  }
}
console.log(`wrote ${n} icons to ${outDir}`);
