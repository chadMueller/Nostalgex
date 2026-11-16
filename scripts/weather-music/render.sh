#!/bin/bash
# Renders scripts/weather-music/local-forecast.mid into public/weather/music/local-forecast.{m4a,mp3}.
#
#   scripts/weather-music/render.sh /path/to/FluidR3_GM.sf2
#
# FluidR3_GM (Frank Wen, MIT licence): the Debian package fluid-soundfont-gm, /usr/share/sounds/sf2/FluidR3_GM.sf2.
# Needs fluidsynth, ffmpeg, lame and (on a Mac) afconvert. The loop is 64 bars at 92 BPM = 256 beats of 652174 us.
set -euo pipefail
SF2="${1:?usage: render.sh FluidR3_GM.sf2}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../../public/weather/music"
WORK="$(mktemp -d)"
mkdir -p "$OUT"
LOOP_S=$(python3 -c "print(256 * 652174 / 1e6)")
fluidsynth -ni -g 0.8 -r 44100 -T wav -O s16 -F "$WORK/raw.wav" "$SF2" "$HERE/local-forecast.mid" >/dev/null
python3 "$HERE/loop.py" "$WORK/raw.wav" "$WORK/loop.wav" "$LOOP_S"
# A level that sits under the screens: -27 LUFS integrated, peaks held under -6 dBFS.
MEAS=$(ffmpeg -nostats -i "$WORK/loop.wav" -af ebur128=peak=true -f null - 2>&1 | awk '/Integrated loudness:/{f=1} f&&/I:/{print $2; exit}')
GAIN=$(python3 -c "print(round(-27 - ($MEAS), 2))")
ffmpeg -y -loglevel error -i "$WORK/loop.wav" -af "volume=${GAIN}dB,alimiter=limit=0.5:level=disabled" "$WORK/final.wav"
afconvert -f m4af -d aac -b 80000 -q 127 "$WORK/final.wav" "$OUT/local-forecast.m4a"
lame --silent --cbr -b 80 -m j --resample 44.1 "$WORK/final.wav" "$OUT/local-forecast.mp3"
echo "measured $MEAS LUFS, gain ${GAIN} dB"
ls -la "$OUT"
rm -rf "$WORK"
