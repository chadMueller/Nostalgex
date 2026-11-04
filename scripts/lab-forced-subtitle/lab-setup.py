#!/usr/bin/env python3
"""N-013: first-run setup of a LAB Emby or Jellyfin, over its HTTP API.

  lab-setup.py emby|jellyfin http://127.0.0.1:8196 CRED_FILE

Runs the startup wizard, makes one lab user with a generated password, adds /media/Movies
as a Movies library (internet metadata off), waits for the scan, signs in, and writes
{url, user, password, userId, token} to CRED_FILE with mode 0600. Prints only counts.
Stdlib only. Only ever points at a lab server on this Mac.
"""
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request

KIND, URL, CRED = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3]
AUTH_HDR = 'MediaBrowser Client="n013-lab", Device="lab", DeviceId="n013-lab-setup", Version="1.0"'


def call(method, path, body=None, token=None, ok=(200, 204)):
    # a server that has just started can drop the first few requests; retry connection errors
    for attempt in range(8):
        try:
            return _call(method, path, body, token, ok)
        except (ConnectionError, urllib.error.URLError, OSError):
            if attempt == 7:
                raise
            time.sleep(2)


def _call(method, path, body=None, token=None, ok=(200, 204)):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    hdr = AUTH_HDR + (f', Token="{token}"' if token else "")
    req.add_header("X-Emby-Authorization", hdr)
    req.add_header("Authorization", hdr)
    if token:
        req.add_header("X-Emby-Token", token)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw.strip().startswith((b"{", b"[")) else raw)
    except urllib.error.HTTPError as e:
        raw = e.read()
        if e.code in ok:
            return e.code, raw
        raise SystemExit(f"{method} {path} -> HTTP {e.code}: {raw[:200]!r}")


# 1. wait for the server to answer
for _ in range(120):
    try:
        _, info = call("GET", "/System/Info/Public")
        break
    except (SystemExit, urllib.error.URLError, ConnectionError, OSError):
        time.sleep(1)
else:
    raise SystemExit("server never answered /System/Info/Public")
print(f"{KIND} {info.get('Version')} up, wizard completed={info.get('StartupWizardCompleted')}")
time.sleep(3)

password = secrets.token_urlsafe(18)
user = "labuser"
if not info.get("StartupWizardCompleted"):
    call("POST", "/Startup/Configuration",
         {"UICulture": "en-US", "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en"})
    call("GET", "/Startup/User")
    call("POST", "/Startup/User", {"Name": user, "Password": password})
    call("POST", "/Startup/RemoteAccess", {"EnableRemoteAccess": False, "EnableAutomaticPortMapping": False}, ok=(200, 204, 404))
    call("POST", "/Startup/Complete", ok=(200, 204))
    time.sleep(2)
else:
    raise SystemExit("wizard already completed: start from a fresh container")

# 2. sign in
_, auth = call("POST", "/Users/AuthenticateByName", {"Username": user, "Pw": password})
token, uid = auth["AccessToken"], auth["User"]["Id"]

# 3. library (internet metadata off so fake titles are left alone)
opts = {"LibraryOptions": {"PathInfos": [{"Path": "/media/Movies"}],
                           "EnableInternetProviders": False, "EnableRealtimeMonitor": False,
                           "SaveLocalMetadata": False}}
call("POST", "/Library/VirtualFolders?name=Movies&collectionType=movies&refreshLibrary=true"
     "&paths=%2Fmedia%2FMovies", opts, token=token)

# 4. wait for the scan to find the films
count = 0
for _ in range(120):
    _, items = call("GET", f"/Users/{uid}/Items?Recursive=true&IncludeItemTypes=Movie&Fields=MediaStreams", token=token)
    count = items.get("TotalRecordCount", 0)
    if count >= 10:
        break
    time.sleep(1)
print(f"library items: {count}")

fd = os.open(CRED, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"kind": KIND, "url": URL, "user": user, "password": password,
               "userId": uid, "token": token, "version": info.get("Version")}, f)
print(f"credentials written to {CRED} (mode 600); not printed")
