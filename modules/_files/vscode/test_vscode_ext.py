"""Offline tests for vscode_ext.py and vscode_profiles.py.

Run with `just vscode-ext-check`. Nothing here touches the network, VS Code or the real
HOME: the modules read $HOME at import time, so every test imports them with a fresh
temporary one. What cannot be tested offline (the Marketplace queries, `code
--list-extensions`) was measured by hand on 2026-11-05 and is written up in
docs/vscode.md.
"""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name: str, home: str):
    os.environ["HOME"] = home
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def vsix(pkg: dict, files: dict[str, bytes] | None = None, symlink: tuple[str, str] | None = None,
         exec_name: str | None = None) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("extension/package.json", json.dumps(pkg))
        for n, b in (files or {}).items():
            z.writestr(n, b)
        if exec_name:
            zi = zipfile.ZipInfo(exec_name)
            zi.external_attr = (stat.S_IFREG | 0o755) << 16
            z.writestr(zi, b"#!/bin/sh\n")
        if symlink:
            zi = zipfile.ZipInfo(symlink[0])
            zi.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(zi, symlink[1])
    return buf.getvalue()


class Jsonc(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ve = load("vscode_ext", self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def parse(self, text: str):
        return json.loads(self.ve.strip_jsonc(text))

    def test_comments_and_trailing_commas(self):
        d = self.parse('{\n // c\n "a": [ "x", /* y */ "z", ], // t\n}\n')
        self.assertEqual(d, {"a": ["x", "z"]})

    def test_comment_markers_inside_strings_survive(self):
        d = self.parse('{"u": "https://example.invalid/a//b", "c": "/* not a comment */"}')
        self.assertEqual(d["u"], "https://example.invalid/a//b")
        self.assertEqual(d["c"], "/* not a comment */")

    def test_escaped_quote_in_string(self):
        self.assertEqual(self.parse(r'{"a": "q\"//x"}'), {"a": 'q"//x'})

    def test_a_comma_between_values_is_kept(self):
        self.assertEqual(self.parse('["a", "b"]'), ["a", "b"])

    def test_repo_style_file(self):
        text = '''{
          // What this REPOSITORY expects.
          "recommendations": [
            // 53 *.nix files.
            "jnoortheen.nix-ide",
            "ms-python.python"
          ],
          "unwantedRecommendations": [
            // Syntax only, last published 2020.
            "bbenoist.nix"
          ]
        }'''
        d = self.parse(text)
        self.assertEqual(d["recommendations"], ["jnoortheen.nix-ide", "ms-python.python"])
        self.assertEqual(d["unwantedRecommendations"], ["bbenoist.nix"])


class Unpack(unittest.TestCase):
    PKG = {"publisher": "Acme", "name": "tool", "version": "1.2.3"}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ve = load("vscode_ext", self.tmp.name)
        self.dest = Path(self.tmp.name) / "out"

    def tearDown(self):
        self.tmp.cleanup()

    def test_unpacks_and_keeps_exec_bit(self):
        data = vsix(self.PKG, {"extension/a/b.txt": b"x"}, exec_name="extension/bin/ls")
        self.ve.unpack(data, self.dest, "acme.TOOL", "1.2.3")      # id compare is case-blind
        self.assertEqual((self.dest / "a/b.txt").read_bytes(), b"x")
        self.assertTrue(os.access(self.dest / "bin/ls", os.X_OK))

    def test_refuses_a_different_extension(self):
        # What a compromised CDN would serve: a valid, checksummed zip of something else.
        with self.assertRaises(self.ve.Fail):
            self.ve.unpack(vsix(self.PKG), self.dest, "other.tool", "1.2.3")
        with self.assertRaises(self.ve.Fail):
            self.ve.unpack(vsix(self.PKG), self.dest, "acme.tool", "9.9.9")

    def test_refuses_zip_slip(self):
        data = vsix(self.PKG, {"extension/../../escape.txt": b"x"})
        with self.assertRaises(self.ve.Fail):
            self.ve.unpack(data, self.dest, "acme.tool", "1.2.3")
        self.assertFalse((Path(self.tmp.name) / "escape.txt").exists())

    def test_refuses_escaping_symlink(self):
        for target in ("/etc/passwd", "../../outside"):
            with self.assertRaises(self.ve.Fail):
                self.ve.unpack(vsix(self.PKG, symlink=("extension/l", target)),
                               self.dest / target.replace("/", "_"), "acme.tool", "1.2.3")

    def test_refuses_non_zip_and_missing_manifest(self):
        with self.assertRaises(self.ve.Fail):
            self.ve.unpack(b"not a zip", self.dest, "acme.tool", "1.2.3")
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("extension/readme.md", "x")
        with self.assertRaises(self.ve.Fail):
            self.ve.unpack(buf.getvalue(), self.dest, "acme.tool", "1.2.3")


class Download(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ve = load("vscode_ext", self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_checksum_is_enforced_offline_part(self):
        # download() needs the network; its two refusals that do not are tested here by
        # patching urlopen.
        data = b"payload"

        class R:
            def __enter__(s): return s
            def __exit__(s, *a): return False
            def read(s, n): return data

        self.ve.urllib.request.urlopen = lambda *a, **k: R()
        ok = hashlib.sha256(data).hexdigest()
        self.assertEqual(self.ve.download("http://x.invalid", ok), data)
        with self.assertRaises(self.ve.Fail):
            self.ve.download("http://x.invalid", "0" * 64)
        with self.assertRaises(self.ve.Fail):                 # no published checksum
            self.ve.download("http://x.invalid", None)


class Entries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ve = load("vscode_ext", self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_installed_entry_has_no_relative_location_and_is_readable(self):
        pkg = {"publisher": "Acme", "name": "tool", "version": "1.2.3"}
        data = vsix(pkg)
        self.ve.download = lambda url, sha: data
        item = {"id": "Acme.tool", "version": "1.2.3", "targetPlatform": "universal",
                "sha256": "x", "vsixUrl": "http://x.invalid"}
        entries = self.ve.install_item(item, [])
        e = entries[0]
        self.assertNotIn("relativeLocation", e)
        self.assertEqual(self.ve.resolved_path(e), e["location"]["fsPath"])
        self.assertTrue(self.ve.readable(e))

    def test_a_relative_location_into_the_wrong_root_is_invalid_until_healed(self):
        # The measured failure: VS Code read ~/.vscode/extensions/<rel>/package.json.
        real = Path(self.tmp.name) / "profiles-root/acme.tool-1.0.0"
        real.mkdir(parents=True)
        (real / "package.json").write_text("{}")
        e = {"identifier": {"id": "acme.tool"}, "version": "1.0.0",
             "relativeLocation": "acme.tool-1.0.0",
             "location": {"fsPath": str(real), "path": str(real), "scheme": "file"}}
        self.assertFalse(self.ve.readable(e))          # what the Extensions view complained about
        self.ve.heal([e])
        self.assertNotIn("relativeLocation", e)
        self.assertTrue(self.ve.readable(e))

    def test_a_location_inside_the_default_root_keeps_its_relative_location(self):
        inside = self.ve.DEFAULT_EXT_ROOT / "acme.tool-1.0.0"
        e = {"identifier": {"id": "acme.tool"}, "version": "1.0.0",
             "relativeLocation": "acme.tool-1.0.0",
             "location": {"fsPath": str(inside), "path": str(inside), "scheme": "file"}}
        self.ve.heal([e])
        self.assertEqual(e["relativeLocation"], "acme.tool-1.0.0")


class Plan(unittest.TestCase):
    """plan_for() against a fake supply-chain module."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ve = load("vscode_ext", self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def sc(self, table: dict[str, list[dict]]):
        ve = self.ve

        class ToolError(Exception):
            pass

        class SC:
            pass

        sc = SC()
        sc.ToolError = ToolError
        sc.load_manifest = lambda: {"cooldown": {"extensions": 14}}

        def closure(ext_id, cutoff, now, done, *a, **k):
            if ext_id.lower() not in table:
                raise ToolError("too new")
            for item in table[ext_id.lower()]:
                done[item["id"].lower()] = item
        sc.extension_closure = closure
        return sc

    def item(self, id_, ver="1.0.0"):
        return {"id": id_, "version": ver, "ageDays": 20.0, "domainVerified": True,
                "installs": 5, "targetPlatform": "universal", "needs": []}

    def test_members_are_planned_once_and_installed_skipped_blocked(self):
        a, m, b = self.item("p.a"), self.item("p.member"), self.item("p.b")
        sc = self.sc({"p.a": [m, a], "p.b": [m, b]})
        installed = {"p.b": {"version": "1.0.0"}}
        table, plan, skips, blocked, days = self.ve.plan_for(
            sc, ["p.a", "p.b", "p.young", "p.nix"], installed, {"p.nix"})
        self.assertEqual([i["id"] for i in plan], ["p.member", "p.a"])
        self.assertEqual([s[0] for s in skips], ["p.b", "p.nix"])   # installed / Nix-provided
        self.assertIn("p.young", [b_[0] for b_ in blocked])
        self.assertEqual(days, 14)

    def test_an_installed_other_version_is_kept_not_replaced(self):
        sc = self.sc({"p.a": [self.item("p.a", "2.0.0")]})
        table, plan, skips, blocked, _ = self.ve.plan_for(
            sc, ["p.a"], {"p.a": {"version": "1.0.0"}}, set())
        self.assertEqual(plan, [])
        self.assertTrue(any("kept" in why for _, why in skips))


class Profiles(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.vp = load("vscode_profiles", self.tmp.name)
        self.vp.vscode_running = lambda: False
        self.home = Path(self.tmp.name)
        self.spec_dir = self.home / "spec"
        self.spec_dir.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def entry(self, id_, store=True):
        path = f"/nix/store/xxx-{id_}" if store else str(self.home / id_)
        return {"identifier": {"id": id_}, "version": "1",
                "location": {"$mid": 1, "fsPath": path, "path": path, "scheme": "file"}}

    def run_main(self, profiles: dict):
        spec = {"flags": {"settings": True}, "profiles": {}}
        for name, (nix, entries) in profiles.items():
            f = self.spec_dir / f"{name}.json"
            f.write_text(json.dumps(entries))
            spec["profiles"][name] = {"nix": nix, "entries": str(f)}
        sf = self.spec_dir / "spec.json"
        sf.write_text(json.dumps(spec))
        sys.argv = ["vscode_profiles.py", "--spec", str(sf)]
        return self.vp.main()

    def test_registers_and_merges_without_losing_runtime_installs(self):
        storage = self.vp.STORAGE
        storage.parent.mkdir(parents=True)
        storage.write_text(json.dumps({"other": 1, "userDataProfiles": [
            {"name": "Agents", "location": "builtin/agents"}]}))
        self.assertEqual(self.run_main({"java": (True, [self.entry("a.java")]),
                                        "oneoff": (False, [])}), 0)
        d = json.loads(storage.read_text())
        names = [p["name"] for p in d["userDataProfiles"]]
        self.assertEqual(names, ["Agents", "java", "oneoff"])
        self.assertEqual(d["other"], 1)
        self.assertEqual(d["userDataProfiles"][1]["useDefaultFlags"], {"settings": True})

        # a runtime install, then Nix changes its mind about its own entry
        target = self.vp.PROFILES_DIR / "oneoff/extensions.json"
        target.write_text(json.dumps([self.entry("x.mine", store=False)]))
        self.assertEqual(self.run_main({"java": (True, [self.entry("a.java")]),
                                        "oneoff": (False, [self.entry("g.general")])}), 0)
        ids = [e["identifier"]["id"] for e in json.loads(target.read_text())]
        self.assertEqual(sorted(ids), ["g.general", "x.mine"])
        sidecar = json.loads(self.vp.SIDECAR.read_text())
        self.assertEqual(sidecar, {"profiles": ["java"]})        # oneoff is not Nix-owned

    def test_local_extension_is_added_once_and_survives(self):
        self.vp.STORAGE.parent.mkdir(parents=True)
        local = {"id": "local.theme", "version": "1.0.0", "dir": str(self.home / "theme")}
        f = self.spec_dir / "a.json"
        f.write_text("[]")
        sf = self.spec_dir / "spec.json"
        sf.write_text(json.dumps({"flags": {}, "local": [local],
                                  "profiles": {"web": {"nix": True, "entries": str(f)}}}))
        for _ in range(2):
            sys.argv = ["x", "--spec", str(sf)]
            self.assertEqual(self.vp.main(), 0)
        ids = [e["identifier"]["id"]
               for e in json.loads((self.vp.PROFILES_DIR / "web/extensions.json").read_text())]
        self.assertEqual(ids, ["local.theme"])

    def test_a_broken_relative_location_is_healed_and_rewritten(self):
        # What the first version wrote: toExtensionJson's `relativeLocation = <id>`, which
        # VS Code resolves against ~/.vscode/extensions and not against `location`.
        self.vp.STORAGE.parent.mkdir(parents=True)
        broken = self.entry("a.java")
        broken["relativeLocation"] = "a.java"
        target = self.vp.PROFILES_DIR / "java/extensions.json"
        target.parent.mkdir(parents=True)
        target.write_text(json.dumps([broken]))
        self.run_main({"java": (True, [broken])})
        e = json.loads(target.read_text())[0]
        self.assertNotIn("relativeLocation", e)
        self.assertTrue(e["location"]["fsPath"].startswith("/nix/store/"))

    def test_second_run_changes_nothing(self):
        self.vp.STORAGE.parent.mkdir(parents=True)
        self.run_main({"java": (True, [self.entry("a.java")])})
        before = (self.vp.STORAGE.read_text(),
                  (self.vp.PROFILES_DIR / "java/extensions.json").stat().st_mtime_ns)
        self.run_main({"java": (True, [self.entry("a.java")])})
        after = (self.vp.STORAGE.read_text(),
                 (self.vp.PROFILES_DIR / "java/extensions.json").stat().st_mtime_ns)
        self.assertEqual(before, after)

    def test_refuses_to_register_while_vscode_runs(self):
        self.vp.STORAGE.parent.mkdir(parents=True)
        self.vp.STORAGE.write_text(json.dumps({"userDataProfiles": []}))
        self.vp.vscode_running = lambda: True
        self.assertEqual(self.run_main({"java": (True, [self.entry("a.java")])}), 1)
        self.assertEqual(json.loads(self.vp.STORAGE.read_text())["userDataProfiles"], [])
        self.assertFalse((self.vp.PROFILES_DIR / "java/extensions.json").exists())


if __name__ == "__main__":
    unittest.main()
