#!/usr/bin/env python3
"""Logging reverse proxy for the N-013 lab (Emby or Jellyfin).

Point the app at http://127.0.0.1:<listen> instead of the server. Every request is
forwarded unchanged and one JSON line is written per request:

  ts       unix time the request arrived (matches the harness transcript)
  t        seconds since the proxy started
  ms       how long the upstream took to answer
  method, path   path with every token / api_key value replaced by TOKEN
  status, bytes  what the server answered
  req      for PlaybackInfo POSTs: the burn-in fields the app asked for
  resp     for PlaybackInfo answers: whether a TranscodingUrl came back
  err      first 200 characters of an error body (4xx / 5xx only)

Fault injection (optional 4th argument: a MODE FILE, re-read on every request, so the mode can
change while the app runs; `echo segments > mode.txt`). It reproduces what an Emby 4.10.1.0 on
macOS answered when asked to burn a subtitle in: HTTP 500 after ~0.12 s, body
"An item with the same key has already been added. Key: threads", ffmpeg never started.
Only requests that ask for a BURNED subtitle are touched (SubtitleStreamIndex >= 0 in the
PlaybackInfo body or in the stream URL); the same film without a burn passes through.

  off           nothing injected (default)
  playbackinfo  500 on the PlaybackInfo POST that asks for a burn
  variant       500 on the variant playlist (main.m3u8) of a burn stream
  segments      500 on every media segment of a burn stream; master and variant answer 200
                (the shape that macOS Emby was measured giving)

An injected response is logged with "injected": <mode>. Real answers carry no such key.

Usage: logproxy.py UPSTREAM LISTEN_PORT LOGFILE [MODEFILE]   (e.g. http://127.0.0.1:8196 8197 run.jsonl mode.txt)
Stdlib only. Tokens are read from the traffic and redacted; nothing secret is written.
"""
import http.client
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse, urlsplit

UPSTREAM = urlparse(sys.argv[1])
PORT = int(sys.argv[2])
LOG = open(sys.argv[3], "a", buffering=1)
MODEFILE = sys.argv[4] if len(sys.argv) > 4 else None
INJECT_BODY = b"An item with the same key has already been added. Key: threads"
INJECT_DELAY = 0.12
T0 = time.time()
LOCK = threading.Lock()
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
       "trailers", "transfer-encoding", "upgrade", "host", "content-length"}


def redact(s):
    s = re.sub(r"(api_key|ApiKey|X-Emby-Token|X-MediaBrowser-Token)=[^&\s\"]+", r"\1=TOKEN", s)
    s = re.sub(r"(Token=\")[^\"]+(\")", r"\1TOKEN\2", s)
    return s


def summarize_request(path, body):
    if "/PlaybackInfo" not in path or not body:
        return None
    try:
        b = json.loads(body)
    except Exception:
        return {"unparsed": True}
    sp = b.get("DeviceProfile", {}).get("SubtitleProfiles", [])
    methods = sorted({p.get("Method") for p in sp})
    tp = b.get("DeviceProfile", {}).get("TranscodingProfiles", [{}])[0]
    return {
        "SubtitleStreamIndex": b.get("SubtitleStreamIndex"),
        "SubtitleProfileMethods": methods,
        "EnableDirectPlay": b.get("EnableDirectPlay"),
        "EnableDirectStream": b.get("EnableDirectStream"),
        "TranscodeContainer": tp.get("Container"),
        "TranscodeVideoCodec": tp.get("VideoCodec"),
        "MediaSourceId": b.get("MediaSourceId"),
    }


def summarize_response(path, data):
    if "/PlaybackInfo" not in path:
        return None
    try:
        j = json.loads(data)
    except Exception:
        return None
    out = []
    for s in j.get("MediaSources", []):
        tu = s.get("TranscodingUrl")
        out.append({
            "SupportsDirectPlay": s.get("SupportsDirectPlay"),
            "SupportsDirectStream": s.get("SupportsDirectStream"),
            "TranscodingUrl": redact(tu)[:260] if tu else None,
            "SubtitleStreams": [
                {"Index": m.get("Index"), "Lang": m.get("Language"), "Forced": m.get("IsForced"),
                 "Default": m.get("IsDefault"), "DeliveryMethod": m.get("DeliveryMethod")}
                for m in s.get("MediaStreams", []) if m.get("Type") == "Subtitle"],
        })
    return out


def mode():
    try:
        return open(MODEFILE).read().strip() if MODEFILE else "off"
    except OSError:
        return "off"


BURN_SESSIONS = set()   # PlaySessionIds whose master/variant asked for a burn


def burn_in_url(path):
    """True when the request belongs to a burn stream. Master and variant URLs carry
    SubtitleStreamIndex; segment URLs carry only PlaySessionId, so the session is remembered."""
    q = parse_qs(urlsplit(path).query)
    session = (q.get("PlaySessionId") or [None])[0]
    for v in q.get("SubtitleStreamIndex", []):
        try:
            if int(v) >= 0:
                if session:
                    BURN_SESSIONS.add(session)
                return True
        except ValueError:
            pass
    return session in BURN_SESSIONS


def is_segment(path):
    base = urlsplit(path).path.lower()
    return "/hls" in base and not base.endswith(".m3u8")


def should_inject(method, path, body):
    m = mode()
    if m == "off":
        return None
    if m == "playbackinfo" and method == "POST" and "/PlaybackInfo" in path:
        try:
            if int(json.loads(body).get("SubtitleStreamIndex", -1)) >= 0:
                return m
        except Exception:
            pass
        return None
    if not burn_in_url(path):
        return None
    base = urlsplit(path).path.lower()
    if m == "variant" and base.endswith("main.m3u8"):
        return m
    if m == "segments" and is_segment(path):
        return m
    return None


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _go(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        t = time.time()
        conn = http.client.HTTPConnection(UPSTREAM.hostname, UPSTREAM.port, timeout=180)
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        status, rbody, rhdrs = 502, b"", []
        injected = should_inject(self.command, self.path, body)
        if injected:
            time.sleep(INJECT_DELAY)
            status, rbody, rhdrs = 500, INJECT_BODY, [("Content-Type", "text/plain")]
        else:
            try:
                conn.request(self.command, self.path, body=body or None, headers=hdrs)
                r = conn.getresponse()
                rbody = r.read()
                status, rhdrs = r.status, r.getheaders()
            except Exception as e:  # upstream down: say so plainly
                rbody = str(e).encode()
        ms = int((time.time() - t) * 1000)
        rec = {"ts": round(t, 3), "t": round(t - T0, 3), "ms": ms, "method": self.command, "path": redact(self.path),
               "status": status, "bytes": len(rbody)}
        if injected:
            rec["injected"] = injected
        rq = summarize_request(self.path, body)
        if rq:
            rec["req"] = rq
        rs = summarize_response(self.path, rbody) if status == 200 else None
        if rs:
            rec["resp"] = rs
        if status >= 400:
            rec["err"] = redact(rbody[:200].decode("utf-8", "replace"))
        with LOCK:
            LOG.write(json.dumps(rec) + "\n")
        try:
            self.send_response(status)
            for k, v in rhdrs:
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(rbody)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(rbody)
        except (BrokenPipeError, ConnectionResetError):
            pass

    do_GET = do_POST = do_HEAD = do_DELETE = do_PUT = _go


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    srv.daemon_threads = True
    print(f"logproxy {PORT} -> {UPSTREAM.geturl()} log={sys.argv[3]}", flush=True)
    srv.serve_forever()
