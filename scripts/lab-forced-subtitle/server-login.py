#!/usr/bin/env python3
"""N-013: sign in to an Emby or Jellyfin server and write a credentials file for probe-burn.py.

  server-login.py emby|jellyfin http://SERVER:8096 USERNAME CRED_FILE

The password is asked for on the terminal (getpass), is sent only to that server, and is
never printed or stored. CRED_FILE gets {kind, url, user, userId, token} with mode 0600.
Then:  probe-burn.py CRED_FILE "<a film with a forced track>" "<a 10-bit film>" "<a plain 8-bit film>"
It only reads (PlaybackInfo, playlists, three segments) and starts at most a few short
transcodes; nothing on the server is changed. Delete CRED_FILE afterwards.
"""
import getpass
import json
import os
import sys
import urllib.error
import urllib.request

kind, url, user, cred = sys.argv[1], sys.argv[2].rstrip("/"), sys.argv[3], sys.argv[4]
pw = getpass.getpass(f"Password for {user} on {url}: ")
hdr = 'MediaBrowser Client="n013-probe", Device="probe", DeviceId="n013-probe-login", Version="1.0"'
req = urllib.request.Request(
    url + "/Users/AuthenticateByName", data=json.dumps({"Username": user, "Pw": pw}).encode(), method="POST",
    headers={"Content-Type": "application/json", "Accept": "application/json",
             "X-Emby-Authorization": hdr, "Authorization": hdr})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        j = json.loads(r.read())
except urllib.error.HTTPError as e:
    raise SystemExit(f"sign-in refused: HTTP {e.code}")
fd = os.open(cred, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"kind": kind, "url": url, "user": user, "userId": j["User"]["Id"], "token": j["AccessToken"]}, f)
print(f"signed in; credentials written to {cred} (mode 600), nothing printed")
