#!/bin/bash
# N-013: ten tiny synthetic films for a lab Emby / Jellyfin. No copyrighted media.
# One 60 s 640x360 8-bit H.264 + AAC base clip (ffmpeg lavfi test sources), remuxed with
# different subtitle layouts. The subtitle text is made-up ("[Synthetic alien dialogue]").
#
#   make-media.sh OUTDIR            -> OUTDIR/Movies/<Title (Year)>/<Title (Year)>.<ext>   (the ten films below)
#   make-media.sh OUTDIR variants   -> six more, 65 s each (the app drops anything under one minute), that differ in the SOURCE (not the subtitles):
#       Ten Bit Forced Film (2001) / Ten Bit Plain Film (2002)   H.264 High10 640x360
#       Full HD Forced Film (2003)                               H.264 8-bit 1920x1080
#       HEVC Forced Film (2004)                                  HEVC 8-bit hvc1 1280x720
#       HDR Forced Film (2005) / HDR Plain Film (2006)           HEVC 10-bit BT.2020 PQ (HDR10) 1280x720
#       UHD Forced Film (2007) / UHD Forced Two (2008)           H.264 8-bit 3840x2160 at 8 fps (the app's watchdog waits
#                                                                40 s, not 20 s, for a UHD source)
#
# Layouts (what each one tests):
#   Forced Lines Film (1991)     MKV, one SRT track, English, FORCED        <- the burn-in case
#   Forced And Full Film (1995)  MKV, English full (default) + English forced   (common retail-rip layout)
#   Forced Lines Two/Three       MKV, same as 1991 (channel tests need several)
#   Forced Lines MP4 (1996)      MP4, mov_text English forced               (direct-play class)
#   Forced Spanish Film (1994)   MKV, Spanish forced only                   (language does not match en)
#   Default Subs Film (1993)     MKV, English full subtitles, default, not forced (never burned)
#   Plain Control Film (1992) / Two (1999) / Three (2000)   MKV, no subtitles (controls)
set -euo pipefail
OUT="${1:?usage: make-media.sh OUTDIR}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"   # absolute: the script cd's into a temp dir
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
M="$OUT/Movies"; mkdir -p "$M"
cd "$W"
cat > en_forced.srt <<'EOF'
1
00:00:05,000 --> 00:00:09,000
[Synthetic alien dialogue] Kala sul tera.

2
00:00:20,000 --> 00:00:24,000
[Synthetic alien dialogue] Mora ven ita.

3
00:00:40,000 --> 00:00:44,000
[Synthetic alien dialogue] Sul kala mora.
EOF
cat > en_full.srt <<'EOF'
1
00:00:02,000 --> 00:00:06,000
Full English subtitle line one.

2
00:00:12,000 --> 00:00:16,000
Full English subtitle line two.

3
00:00:30,000 --> 00:00:34,000
Full English subtitle line three.
EOF
cat > es_forced.srt <<'EOF'
1
00:00:05,000 --> 00:00:09,000
[Dialogo sintetico] Hola amigo.

2
00:00:20,000 --> 00:00:24,000
[Dialogo sintetico] Adios amigo.
EOF
F="ffmpeg -hide_banner -loglevel error -y"
mk() { local name="$1" ext="$2"; shift 2; mkdir -p "$M/$name"; nice -n 15 $F "$@" "$M/$name/$name.$ext"; }
if [ "${2:-}" = "variants" ]; then
  tenbit="-c:v libx264 -preset veryfast -crf 27 -pix_fmt yuv420p10le -profile:v high10 -g 48"
  hdr="-c:v libx265 -preset veryfast -crf 28 -pix_fmt yuv420p10le -tag:v hvc1 -x265-params colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:log-level=error:pools=2"
  v() { # title ext size videoopts [withsub]
    local name="$1" ext="$2" size="$3" vopts="$4" withsub="${5:-}" fps="${6:-24}"
    mkdir -p "$M/$name"
    if [ -n "$withsub" ]; then
      nice -n 15 $F -threads 2 -f lavfi -i "testsrc2=size=$size:rate=$fps:duration=65" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=65" -i en_forced.srt \
        -map 0:v -map 1:a -map 2:0 $vopts -c:a aac -b:a 96k -ac 2 -c:s srt -metadata:s:s:0 language=eng -disposition:s:0 forced "$M/$name/$name.$ext"
    else
      nice -n 15 $F -threads 2 -f lavfi -i "testsrc2=size=$size:rate=$fps:duration=65" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=65" \
        -map 0:v -map 1:a $vopts -c:a aac -b:a 96k -ac 2 "$M/$name/$name.$ext"
    fi
  }
  v "Ten Bit Forced Film (2001)" mkv 640x360   "$tenbit" sub
  v "Ten Bit Plain Film (2002)"  mkv 640x360   "$tenbit"
  v "Full HD Forced Film (2003)" mkv 1920x1080 "-c:v libx264 -preset veryfast -crf 28 -pix_fmt yuv420p -profile:v high -g 48" sub
  v "HEVC Forced Film (2004)"    mkv 1280x720  "-c:v libx265 -preset veryfast -crf 28 -pix_fmt yuv420p -tag:v hvc1 -x265-params log-level=error:pools=2" sub
  v "HDR Forced Film (2005)"     mkv 1280x720  "$hdr" sub
  v "HDR Plain Film (2006)"      mkv 1280x720  "$hdr"
  v "UHD Forced Film (2007)"     mkv 3840x2160 "-c:v libx264 -preset ultrafast -crf 38 -pix_fmt yuv420p -g 16" sub 8
  mkdir -p "$M/UHD Forced Two (2008)"; cp "$M/UHD Forced Film (2007)/UHD Forced Film (2007).mkv" "$M/UHD Forced Two (2008)/UHD Forced Two (2008).mkv"
  find "$M" -type f -newer en_forced.srt | sort
  exit 0
fi
nice -n 15 $F -threads 2 -f lavfi -i "testsrc2=size=640x360:rate=24:duration=60" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=60" \
  -c:v libx264 -preset veryfast -crf 27 -pix_fmt yuv420p -profile:v high -g 48 \
  -c:a aac -b:a 96k -ac 2 base.mp4
forced_en() { mk "$1" mkv -i base.mp4 -i en_forced.srt -map 0:v -map 0:a -map 1:0 -c copy -c:s srt \
  -metadata:s:s:0 language=eng -disposition:s:0 forced; }
forced_en "Forced Lines Film (1991)"
forced_en "Forced Lines Two (1997)"
forced_en "Forced Lines Three (1998)"
mk "Plain Control Film (1992)"  mkv -i base.mp4 -map 0 -c copy
mk "Plain Control Two (1999)"   mkv -i base.mp4 -map 0 -c copy
mk "Plain Control Three (2000)" mkv -i base.mp4 -map 0 -c copy
mk "Default Subs Film (1993)" mkv -i base.mp4 -i en_full.srt -map 0:v -map 0:a -map 1:0 -c copy -c:s srt \
  -metadata:s:s:0 language=eng -disposition:s:0 default
mk "Forced Spanish Film (1994)" mkv -i base.mp4 -i es_forced.srt -map 0:v -map 0:a -map 1:0 -c copy -c:s srt \
  -metadata:s:s:0 language=spa -disposition:s:0 forced
mk "Forced And Full Film (1995)" mkv -i base.mp4 -i en_full.srt -i en_forced.srt -map 0:v -map 0:a -map 1:0 -map 2:0 \
  -c copy -c:s srt -metadata:s:s:0 language=eng -metadata:s:s:1 language=eng \
  -disposition:s:0 default -disposition:s:1 forced
mk "Forced Lines MP4 (1996)" mp4 -i base.mp4 -i en_forced.srt -map 0:v -map 0:a -map 1:0 -c copy -c:s mov_text \
  -metadata:s:s:0 language=eng -disposition:s:0 forced
find "$M" -type f | sort
