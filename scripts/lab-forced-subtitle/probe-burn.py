#!/usr/bin/env python3
"""N-013: what a lab Emby / Jellyfin answers when asked to burn a forced subtitle in.

  probe-burn.py CRED_FILE [title-fragment ...]

Mirrors the app's two PlaybackInfo questions (JellyfinPlaybackResolver.negotiate), with the
device profile the app sends on an Apple TV for H.264 (`Auto` quality = 40 Mbps):

  A  SubtitleStreamIndex=-1, subtitle profiles "External"   (the usual request)
  B  SubtitleStreamIndex=<forced track>, profiles "Encode"  (only when the source lists a
                                                             forced track in the viewer's language)

then walks each TranscodingUrl: master.m3u8, the variant playlist, and segments 0 to 2,
printing status, milliseconds and bytes per hop. A 4xx/5xx body is shown (first 160 chars).
Tokens never print. Stdlib only.
"""
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

cred = json.load(open(sys.argv[1]))
fragments = sys.argv[2:]
URL, TOKEN, UID, KIND = cred["url"].rstrip("/"), cred["token"], cred["userId"], cred["kind"]
AUTH = f'MediaBrowser Client="Nostalgex", Device="Apple TV", DeviceId="n013-probe", Version="1.0", Token="{TOKEN}"'
FORMATS = ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "mov_text", "ttml", "sub", "smi", "sami",
           "pgs", "pgssub", "dvdsub", "vobsub", "dvbsub", "sup", "xsub"]


def red(s):
    return str(s).replace(TOKEN, "TOKEN")


def http(method, url, body=None, headers=None, timeout=90):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read()
            return r.status, int((time.time() - t) * 1000), data
    except urllib.error.HTTPError as e:
        return e.code, int((time.time() - t) * 1000), e.read()
    except Exception as e:
        return 0, int((time.time() - t) * 1000), str(e).encode()


def api(path, method="GET", body=None):
    h = {"X-Emby-Authorization": AUTH, "Authorization": AUTH, "Accept": "application/json",
         "Content-Type": "application/json"}
    st, ms, data = http(method, URL + path, json.dumps(body).encode() if body is not None else None, h)
    return st, ms, (json.loads(data) if data[:1] in (b"{", b"[") else data)


def profile(burning, container):
    return {
        "MaxStreamingBitrate": 40_000_000, "MaxStaticBitrate": 40_000_000,
        "DirectPlayProfiles": [{"Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264",
                                "AudioCodec": "aac,ac3,eac3,mp3"}],
        "TranscodingProfiles": [{"Container": container, "Type": "Video", "VideoCodec": "h264",
                                 "AudioCodec": "aac,ac3,eac3,mp3", "Context": "Streaming",
                                 "MaxAudioChannels": "6", "Protocol": "hls"}],
        "CodecProfiles": [{"Type": "Video", "Codec": "h264", "Conditions": [
            {"Condition": "LessThanEqual", "Property": "VideoBitDepth", "Value": "8", "IsRequired": False}]}],
        "SubtitleProfiles": [{"Format": f, "Method": "Encode" if burning else "External"} for f in FORMATS],
    }


def playback_info(item_id, msid, burn_index):
    container = "ts" if KIND == "emby" else "mp4"
    body = {"DeviceProfile": profile(burn_index is not None, container), "MediaSourceId": msid,
            "MaxStreamingBitrate": 40_000_000,
            "SubtitleStreamIndex": burn_index if burn_index is not None else -1}
    return api(f"/Items/{item_id}/PlaybackInfo?userId={UID}", "POST", body)


def walk(transcoding_url):
    """master -> variant -> segments 0..2; returns a list of (label, status, ms, bytes, note)."""
    rows = []
    u = transcoding_url if transcoding_url.startswith("http") else URL + transcoding_url
    if "api_key=" not in u:
        u += ("&" if "?" in u else "?") + "api_key=" + TOKEN
    st, ms, data = http("GET", u)
    rows.append(("master", st, ms, len(data), "" if st == 200 else red(data[:160].decode("utf-8", "replace"))))
    if st != 200:
        return rows
    lines = [l for l in data.decode().splitlines() if l and not l.startswith("#")]
    variant = urllib.parse.urljoin(u, lines[0])
    st, ms, data = http("GET", variant)
    rows.append(("variant", st, ms, len(data), "" if st == 200 else red(data[:160].decode("utf-8", "replace"))))
    if st != 200:
        return rows
    text = data.decode()
    init = re.search(r'#EXT-X-MAP:URI="([^"]+)"', text)
    segs = [l for l in text.splitlines() if l and not l.startswith("#")]
    todo = ([("init", init.group(1))] if init else []) + [(f"seg{i}", s) for i, s in enumerate(segs[:3])]
    for label, rel in todo:
        st, ms, data = http("GET", urllib.parse.urljoin(variant, rel))
        rows.append((label, st, ms, len(data), "" if st == 200 else red(data[:160].decode("utf-8", "replace"))))
        if st != 200:
            break
    return rows


def show(tag, rows):
    for label, st, ms, n, note in rows:
        print(f"    {tag} {label:8s} HTTP {st:<3} {ms:>6} ms {n:>9} bytes  {note}")


st, _, items = api(f"/Users/{UID}/Items?Recursive=true&IncludeItemTypes=Movie&Fields=MediaSources,MediaStreams")
for it in items["Items"]:
    name = it["Name"]
    if fragments and not any(f in name for f in fragments):
        continue
    src = (it.get("MediaSources") or [{}])[0]
    msid = src.get("Id") or it["Id"]
    subs = [(s["Index"], s.get("Language"), s.get("IsForced"), s.get("IsDefault"), s.get("Codec"))
            for s in (src.get("MediaStreams") or it.get("MediaStreams") or []) if s.get("Type") == "Subtitle"]
    print(f"== {name}  container={src.get('Container')}  subtitle tracks (index, lang, forced, default, codec)={subs}")
    forced = next((i for i, lang, f, d, c in subs if f and (lang or "").lower() in ("eng", "en")), None)
    st, ms, info = playback_info(it["Id"], msid, None)
    s0 = (info.get("MediaSources") or [{}])[0] if isinstance(info, dict) else {}
    print(f"  A usual request (SubtitleStreamIndex=-1): HTTP {st} {ms} ms, DirectPlay={s0.get('SupportsDirectPlay')}, "
          f"TranscodingUrl={'yes' if s0.get('TranscodingUrl') else 'no'}")
    if s0.get("TranscodingUrl"):
        show("A", walk(s0["TranscodingUrl"]))
    if forced is None:
        print("  B burn request: not made (no forced English track), the app asks only A")
        continue
    st, ms, info = playback_info(it["Id"], msid, forced)
    s1 = (info.get("MediaSources") or [{}])[0] if isinstance(info, dict) else {}
    print(f"  B burn request (SubtitleStreamIndex={forced}, Encode): HTTP {st} {ms} ms, DirectPlay={s1.get('SupportsDirectPlay')}, "
          f"TranscodingUrl={'yes' if s1.get('TranscodingUrl') else 'no'}")
    if s1.get("TranscodingUrl"):
        print("    url query keys:", sorted({k for k, _ in urllib.parse.parse_qsl(urllib.parse.urlsplit(s1['TranscodingUrl']).query)} - {"api_key"}))
        show("B", walk(s1["TranscodingUrl"]))
