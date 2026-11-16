#!/usr/bin/env python3
"""
Makes a render loop-exact: the first LOOP seconds of the file are the loop, and what rings on after it (the last notes'
release and the reverb) is mixed back onto the start, so the end of the loop runs into the beginning without a seam.

  python3 loop.py in.wav out.wav LOOP_SECONDS
"""
import array, sys, wave

src, dst, loop_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
with wave.open(src, "rb") as w:
    ch, rate, width, frames = w.getnchannels(), w.getframerate(), w.getsampwidth(), w.getnframes()
    assert width == 2, "16 bit only"
    pcm = array.array("h"); pcm.frombytes(w.readframes(frames))
n = round(loop_s * rate)
assert frames > n, "the render has no tail"
out = array.array("h", pcm[: n * ch])
tail = frames - n
for i in range(tail * ch):
    j = i % (n * ch)
    v = out[j] + pcm[n * ch + i]
    out[j] = max(-32768, min(32767, v))
with wave.open(dst, "wb") as w:
    w.setnchannels(ch); w.setsampwidth(2); w.setframerate(rate); w.writeframes(out.tobytes())
print(f"loop {n} frames ({n / rate:.4f} s), tail of {tail} frames ({tail / rate:.2f} s) mixed onto the start")
