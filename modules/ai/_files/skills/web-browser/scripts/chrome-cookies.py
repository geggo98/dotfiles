#!/usr/bin/env -S uv --quiet run --frozen --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pycryptodome>=3.20"]
# [tool.uv]
# exclude-newer = "30 days"
# ///
"""Export one site's cookies from the everyday Chrome (macOS) as a Playwright storageState.

    chrome-cookies.py app.example.com                      # -> ~/.agent-browser/state/app.example.com.json
    chrome-cookies.py app.example.com --profile "Profile 1" --out ./state.json
    agent-browser --state ~/.agent-browser/state/app.example.com.json open https://app.example.com

Values go ONLY into the target file. stdout carries names, lengths and expiry — never a value.
Chrome stays running and keeps its session; no remote-debugging port, no restart.

How it works: Chrome encrypts cookie values with AES-128-CBC. The key is derived (PBKDF2-HMAC-SHA1,
salt "saltysalt", 1003 rounds) from the Keychain item "Chrome Safe Storage"; macOS asks for
permission on first access — answer "Allow", not "Always Allow". Cookie DB schema version >= 24
(Chrome ~130+) prefixes the plaintext with a 32-byte SHA-256 of the host, which is stripped.

Limits: localStorage / sessionStorage are not exported (`origins` stays empty), so SPAs that keep
their token there are not covered.
Exit codes: 0 done, 1 file written but some cookies failed to decrypt, 2 nothing usable (nothing written),
125 usage/setup. Expired cookies are listed by name on stderr: an expired session cookie is the usual
reason a login "does not work".
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

try:
    from Crypto.Cipher import AES  # pycryptodome
except ImportError:
    sys.exit("pycryptodome missing — run via the uv shebang, not plain python3")

CHROME_DIR = pathlib.Path.home() / "Library/Application Support/Google/Chrome"
EPOCH_DELTA_S = 11_644_473_600  # 1601-01-01 -> 1970-01-01
SAMESITE = {-1: "Lax", 0: "None", 1: "Lax", 2: "Strict"}  # -1 = unspecified, browsers treat as Lax


def host_candidates(domain: str) -> list[str]:
    """app.example.com -> app.example.com, .app.example.com, .example.com (never a bare TLD)."""
    labels = domain.lower().strip(".").split(".")
    if all(l.isdigit() for l in labels):  # IPv4: no parent domains
        return [".".join(labels)]
    out = [domain.lower().strip("."), "." + ".".join(labels)]
    out += ["." + ".".join(labels[i:]) for i in range(1, len(labels) - 1)]
    return out


def safe_storage_key() -> bytes:
    pw = subprocess.run(
        ["security", "find-generic-password", "-w", "-s", "Chrome Safe Storage", "-a", "Chrome"],
        capture_output=True, text=True, check=True,
    ).stdout.strip().encode()
    return hashlib.pbkdf2_hmac("sha1", pw, b"saltysalt", 1003, dklen=16)


def decrypt(blob: bytes, host: bytes, key: bytes) -> bytes:
    """Return the plaintext value as bytes; raise ValueError for anything that does not verify."""
    if blob[:3] not in (b"v10", b"v11"):
        return blob  # stored unencrypted
    body = blob[3:]
    if not body or len(body) % 16:
        raise ValueError("truncated ciphertext")
    raw = AES.new(key, AES.MODE_CBC, IV=b" " * 16).decrypt(body)
    pad = raw[-1]
    if not 1 <= pad <= 16 or raw[-pad:] != bytes([pad]) * pad:
        raise ValueError("bad padding — wrong Keychain key?")
    raw = raw[:-pad]
    # Schema >= 24 prefixes SHA-256(host_key). Strip it only when it verifies: 2190 of 2190 rows matched
    # on Chrome 156, but a row without the prefix must not lose its first 32 bytes.
    if raw[:32] == hashlib.sha256(host).digest():
        raw = raw[32:]
    return raw


def text(raw: bytes) -> str:
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")  # Chrome stores arbitrary bytes; the storageState needs a string


def printable(s: str) -> str:
    """Names come from sites. Escape control characters before they reach a terminal."""
    return s.encode("unicode_escape").decode("ascii")


def copy_database(db: pathlib.Path, dest: pathlib.Path) -> pathlib.Path:
    """Copy the DB with its sidecars; Chrome keeps a rollback journal (or WAL) next to it."""
    for suffix in ("", "-journal", "-wal", "-shm"):
        src = db.with_name(db.name + suffix)
        if src.is_file():
            shutil.copy2(src, dest / src.name)
    return dest / db.name


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("domain", help="exactly one host, e.g. app.example.com (parent-domain cookies are included)")
    ap.add_argument("--profile", default="Default", help='Chrome profile directory (see `agent-browser profiles`)')
    ap.add_argument("--out", help="target file (default ~/.agent-browser/state/<domain>.json)")
    try:
        args = ap.parse_args()
    except SystemExit as e:
        return 125 if e.code else 0  # argparse says 2; 2 means "nothing usable" here
    domain = args.domain.lower().strip(".")
    if not re.fullmatch(r"[a-z0-9.-]+", domain) or "." not in domain or ".." in domain:
        print("error: give one concrete host such as app.example.com", file=sys.stderr)
        return 125
    if "/" in args.profile or args.profile in ("", ".", "..") or args.profile.startswith("."):
        print("error: --profile is a directory name like 'Default' or 'Profile 1'", file=sys.stderr)
        return 125
    out = pathlib.Path(args.out or f"~/.agent-browser/state/{domain}.json").expanduser()
    db = CHROME_DIR / args.profile / "Cookies"
    if not db.is_file():
        print(f"error: no cookie database at {db}", file=sys.stderr)
        return 125

    try:
        key = safe_storage_key()
    except subprocess.CalledProcessError:
        print("error: Keychain access to 'Chrome Safe Storage' denied or missing", file=sys.stderr)
        return 125

    hosts = host_candidates(domain)
    with tempfile.TemporaryDirectory() as tmp:  # copy: the running Chrome holds locks on the original
        con = sqlite3.connect(copy_database(db, pathlib.Path(tmp)))  # read-write on the copy: lets sqlite replay a hot journal
        con.text_factory = bytes  # two rows on this machine are typed TEXT and would not decode
        try:
            schema = int(con.execute("SELECT value FROM meta WHERE key='version'").fetchone()[0])
            cols = {r[1].decode() for r in con.execute("PRAGMA table_info(cookies)")}
            wanted = ["host_key", "name", "encrypted_value", "value", "path", "expires_utc",
                      "is_secure", "is_httponly", "samesite"]
            missing = [c for c in wanted if c not in cols]
            if missing:
                print(f"error: cookie schema v{schema} lacks columns {missing} — Chrome changed the format", file=sys.stderr)
                return 125
            # Partitioned (CHIPS) cookies share name/host/path with the plain one; keep only the plain one.
            partition = " AND top_frame_site_key = ''" if "top_frame_site_key" in cols else ""
            rows = con.execute(
                f"SELECT {', '.join(wanted)} FROM cookies "
                f"WHERE host_key IN ({','.join('?' * len(hosts))}){partition} ORDER BY host_key, name, path",
                hosts,  # str, not bytes: a BLOB parameter never equals a TEXT column. text_factory only affects results
            ).fetchall()
        except (sqlite3.Error, TypeError) as e:
            print(f"error: cannot read the cookie database ({e})", file=sys.stderr)
            return 125

    now = time.time()
    cookies, expired, skip, err = [], [], 0, 0
    for host_b, name_b, blob, plain, path_b, exp, secure, httponly, samesite in rows:
        host, name, path = host_b.decode(), text(name_b), text(path_b)
        expires = exp / 1e6 - EPOCH_DELTA_S if exp else -1
        if expires != -1 and expires < now:
            expired.append(name)
            continue
        try:
            value = text(decrypt(blob, host_b, key) if blob else plain)
        except ValueError as e:
            err += 1
            print(f"  ERROR {printable(name)}: {e}", file=sys.stderr)
            continue
        if not value:
            skip += 1  # empty
            continue
        same = SAMESITE.get(samesite, "Lax")
        cookies.append({
            "name": name, "value": value, "domain": host, "path": path, "expires": expires,
            "secure": bool(secure), "httpOnly": bool(httponly),
            "sameSite": same if bool(secure) or same != "None" else "Lax",  # SameSite=None needs Secure
        })
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(expires)) if expires != -1 else "session"
        print(f"  {printable(host):28} {printable(name):32} {len(value):5} chars  expires {when}{'  httpOnly' if httponly else ''}")

    print(f"{len(cookies)} ok, {skip} skip (empty), {len(expired)} expired, {err} error — schema v{schema}, profile {args.profile}",
          file=sys.stderr)
    if expired:
        print("  expired (not exported): " + ", ".join(sorted({printable(n) for n in expired})), file=sys.stderr)
    if not cookies:
        print(f"no usable cookies for {domain} — logged in there in profile {args.profile}?", file=sys.stderr)
        return 2

    out.parent.mkdir(parents=True, exist_ok=True)
    fd, tmpname = tempfile.mkstemp(dir=out.parent, prefix=out.name + ".tmp.")  # mkstemp is 0600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"cookies": cookies, "origins": []}, f, indent=2)
        os.replace(tmpname, out)  # atomic: only a complete file carries the final name
    except BaseException:
        pathlib.Path(tmpname).unlink(missing_ok=True)  # never leave plaintext cookies behind
        raise
    print(f"written to {out} (mode 600) — values are not in this log", file=sys.stderr)
    return 1 if err else 0  # the file exists, but a cookie is missing from it: say so


if __name__ == "__main__":
    sys.exit(main())
