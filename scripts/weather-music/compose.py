#!/usr/bin/env python3
"""
The weather channel's music: an original late-80s / early-90s "local forecast" bed, written here as MIDI.

  python3 scripts/weather-music/compose.py scripts/weather-music/local-forecast.mid

Nothing in it is taken from a recording or a score: the chords are a plain Eb major smooth-jazz loop (two 8 bar
progressions), the melodies are written below, the arrangement is soft General MIDI voices (electric piano, warm
pad, fretless bass, vibraphone, flute, soprano sax, a little string ensemble, a brushed-feel kit played very
quietly). 92 BPM, 4/4, 64 bars (2:47), written so bar 64 (Bb7sus4) leads straight back into bar 1 (Ebmaj9).

render.sh turns the MIDI into the shipped files (FluidR3_GM, MIT, then a loop-exact wrap, a level for sitting under
the screens, AAC and MP3). The licence of the soundfont is in public/weather/music/LICENSE-FluidR3_GM.txt.
"""
import random
import struct
import sys

PPQ = 480
BPM = 92
US_PER_BEAT = round(60_000_000 / BPM)   # 652174: the render script uses the same number
BARS = 64
TAIL_BARS = 2                           # silence at the end of the file, for the last notes' release and reverb
rng = random.Random(1991)

def vlq(n):
    out = [n & 0x7F]
    n >>= 7
    while n:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    return bytes(reversed(out))

class Track:
    def __init__(self):
        self.ev = []   # (tick, order, bytes)
    def add(self, tick, data, order=1):
        self.ev.append((max(0, int(round(tick))), order, bytes(data)))
    def note(self, ch, tick, dur, pitch, vel):
        self.add(tick, [0x90 | ch, pitch, max(1, min(127, int(vel)))], 2)
        self.add(tick + max(1, dur), [0x80 | ch, pitch, 0], 0)
    def prog(self, ch, tick, p): self.add(tick, [0xC0 | ch, p], 0)
    def cc(self, ch, tick, c, v): self.add(tick, [0xB0 | ch, c, v], 0)
    def chunk(self, end_tick, name=None):
        self.ev.sort(key=lambda e: (e[0], e[1]))
        out = bytearray()
        if name:
            out += vlq(0) + b"\xFF\x03" + vlq(len(name)) + name.encode()
        last = 0
        for t, _, d in self.ev:
            out += vlq(t - last) + d
            last = t
        out += vlq(max(0, end_tick - last)) + b"\xFF\x2F\x00"
        return b"MTrk" + struct.pack(">I", len(out)) + bytes(out)

B = PPQ                      # ticks in a beat
BAR = 4 * B

# Chords: bass root, electric piano voicing, pad voicing (MIDI note numbers).
CH = {
    "Ebmaj9":  (39, [55, 62, 65, 70], [51, 58, 65, 67]),
    "Cm9":     (36, [51, 58, 62, 67], [48, 55, 62, 67]),
    "Abmaj9":  (44, [60, 63, 67, 70], [56, 63, 67, 70]),
    "Bb9sus":  (46, [56, 60, 63, 65], [58, 63, 65, 68]),
    "Gm7":     (43, [53, 58, 62, 67], [55, 58, 62, 65]),
    "Cm7":     (36, [55, 58, 63, 67], [48, 55, 58, 63]),
    "Fm9":     (41, [51, 56, 60, 67], [53, 56, 60, 63]),
    "Bb9":     (46, [56, 60, 62, 65], [58, 62, 65, 68]),
    "Bb7sus4": (46, [56, 60, 63, 65], [58, 65, 68, 70]),
}
P1 = ["Ebmaj9", "Cm9", "Abmaj9", "Bb9sus", "Gm7", "Cm7", "Fm9", "Bb7sus4"]
P2 = ["Abmaj9", "Bb9sus", "Gm7", "Cm7", "Fm9", "Bb9", "Ebmaj9", "Bb7sus4"]

# Melodies, (start beat in the 8 bar phrase, pitch, length in beats).
LEAD_A = [(1.5, 70, 1.0), (2.5, 74, 1.5), (4.5, 72, 1.0), (5.5, 70, 0.5), (6.0, 67, 2.0), (8.5, 68, 1.0), (9.5, 72, 1.0), (10.5, 75, 1.5),
          (12.0, 77, 1.0), (13.0, 75, 1.0), (14.0, 72, 1.0), (15.0, 70, 1.0), (16.5, 70, 1.5), (18.0, 74, 1.0), (19.0, 72, 0.5), (19.5, 70, 0.5),
          (20.5, 67, 1.0), (21.5, 70, 1.0), (22.5, 72, 1.5), (24.0, 68, 1.0), (25.0, 72, 1.0), (26.0, 75, 2.0), (28.5, 77, 1.0), (29.5, 75, 0.5), (30.0, 74, 2.0)]
LEAD_B = [(0.5, 72, 1.0), (1.5, 75, 1.0), (2.5, 79, 1.5), (4.0, 77, 1.0), (5.0, 75, 1.0), (6.0, 72, 2.0), (8.5, 74, 1.0), (9.5, 70, 1.0), (10.5, 67, 1.5),
          (12.5, 67, 1.0), (13.5, 70, 1.0), (14.5, 72, 1.5), (16.0, 72, 1.0), (17.0, 75, 1.0), (18.0, 77, 2.0), (20.0, 74, 1.0), (21.0, 77, 1.0), (22.0, 75, 1.0),
          (23.0, 74, 1.0), (24.5, 70, 1.5), (26.0, 75, 2.0), (28.5, 72, 1.0), (29.5, 70, 0.5), (30.0, 70, 2.0)]

# GM programs, zero based: 4 Electric Piano 1, 88 Warm Pad, 35 Fretless Bass, 11 Vibraphone, 73 Flute, 64 Soprano Sax, 49 String Ensemble 2.
EP, PAD, BASS, VIBES, FLUTE, SOPRANO, STRINGS = 4, 88, 35, 11, 73, 64, 49
# One entry per 8 bar chunk: (progression, bass+drums, lead, strings)
PLAN = [
    (P1, False, None, False),
    (P1, True, (LEAD_A, VIBES, 0, 64), False),
    (P2, True, (LEAD_B, SOPRANO, 0, 62), True),
    (P1, True, (LEAD_A, SOPRANO, 0, 62), False),
    (P2, True, (LEAD_B, FLUTE, 12, 60), True),
    (P1, True, (LEAD_A, VIBES, 0, 60), False),
    (P2, True, (LEAD_B, VIBES, 0, 52), True),
    (P1, False, None, False),
]

tempo = Track()
tempo.add(0, b"\xFF\x51\x03" + struct.pack(">I", US_PER_BEAT)[1:])
tempo.add(0, b"\xFF\x58\x04\x04\x02\x18\x08")
tempo.add(0, b"\xFF\x59\x02\xFD\x00")   # three flats, major: Eb

keys, padt, bass, lead, strings, drums = (Track() for _ in range(6))
# channel setup: program, volume (7), pan (10), reverb (91), chorus (93)
SETUP = [(keys, 0, EP, 84, 50, 72, 55), (padt, 1, PAD, 62, 64, 100, 30), (bass, 2, BASS, 80, 64, 20, 0), (lead, 3, VIBES, 82, 80, 85, 20),
         (strings, 4, STRINGS, 46, 70, 95, 25), (drums, 9, 0, 66, 64, 50, 0)]
for tr, ch, prog, vol, pan, rev, cho in SETUP:
    if ch != 9: tr.prog(ch, 0, prog)
    tr.cc(ch, 0, 7, vol); tr.cc(ch, 0, 10, pan); tr.cc(ch, 0, 91, rev); tr.cc(ch, 0, 93, cho); tr.cc(ch, 0, 11, 110)

def human(span=8):
    return rng.randint(-span, span)

for ci, (prog_, rhythm, lead_cfg, strg) in enumerate(PLAN):
    base = ci * 8 * BAR
    for bar in range(8):
        t0 = base + bar * BAR
        name = prog_[bar]
        root, voice, pad = CH[name]
        last_bar = bar == 7
        # pad: the whole bar, a little over so the next chord blooms in
        for n in pad:
            padt.note(1, t0, BAR + 40, n, 46 if ci in (0, 7) else 52)
        # electric piano: a spread chord, then two light offbeat stabs. The intro and outro just let the chord ring.
        for i, n in enumerate(voice):
            keys.note(0, t0 + i * 14 + human(), 2 * B - 40 if rhythm else 4 * B - 60, n, 60 + rng.randint(-4, 4))
        if rhythm:
            hit = voice if not (last_bar and name == "Bb7sus4") else [56, 62, 65, 70]   # the last bar turns Bb7sus4 into Bb7
            for i, n in enumerate(hit):
                keys.note(0, t0 + int(2.5 * B) + i * 10 + human(), int(0.5 * B), n, 46 + rng.randint(-3, 3))
            for i, n in enumerate(hit):
                keys.note(0, t0 + int(3.5 * B) + i * 10 + human(), int(0.4 * B), n, 50 + rng.randint(-3, 3))
            # bass: root, the fifth on the "and" of 2, the octave on the "and" of 4
            bass.note(2, t0 + human(4), int(1.35 * B), root, 72)
            bass.note(2, t0 + int(2.5 * B) + human(4), int(0.7 * B), root + 7, 60)
            bass.note(2, t0 + int(3.5 * B) + human(4), int(0.4 * B), root + 12, 46)
            # drums: soft kick on 1 and the "and" of 2, side stick on 2 and 4, closed hat on the eighths
            quiet = 0.7 if ci == 6 else 1.0
            drums.note(9, t0 + human(4), 60, 36, 56 * quiet)
            drums.note(9, t0 + int(2.5 * B) + human(4), 60, 36, 44 * quiet)
            for beat in (1, 3):
                drums.note(9, t0 + beat * B + human(4), 60, 37, 40 * quiet)
            for e in range(8):
                drums.note(9, t0 + e * (B // 2) + human(5), 40, 42, (30 if e % 2 == 0 else 21) * quiet)
        if strg:
            for n in (pad[1] + 12, pad[3]):
                strings.note(4, t0, BAR + 30, n, 36)
    if lead_cfg:
        mel, prg, shift, vel = lead_cfg
        lead.prog(3, base, prg)
        for beat, pitch, length in mel:
            lead.note(3, base + beat * B + human(6), int(length * B * 0.94), pitch + shift, vel + rng.randint(-4, 4))

total = (BARS + TAIL_BARS) * BAR
tracks = [t.chunk(total, n) for t, n in ((tempo, "tempo"), (keys, "electric piano"), (padt, "warm pad"), (bass, "fretless bass"),
                                           (lead, "lead"), (strings, "strings"), (drums, "drums"))]
header = b"MThd" + struct.pack(">IHHH", 6, 1, len(tracks), PPQ)
open(sys.argv[1], "wb").write(header + b"".join(tracks))
print(f"wrote {sys.argv[1]}: {BARS} bars at {BPM} BPM, {BARS * 4 * US_PER_BEAT / 1e6:.3f} s loop")
