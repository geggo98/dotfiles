"""Behavioral tests; run with the Nix-provided tomli-w interpreter."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import tomli_w

spec = importlib.util.spec_from_file_location(
    "merger", Path(__file__).parent.parent / "_files/codex-merge-config.py"
)
merger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(merger)


class MergeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.managed = self.root / "managed.toml"
        self.target = self.root / "config.toml"
        self.state = self.root / "state.json"
        self.old = {"url": "https://docs.example.org/mcp"}
        self.new = {"url": "https://docs.example.org/mcp/v2"}

    def desired(self, servers):
        self.managed.write_text(tomli_w.dumps({"mcp_servers": servers}))

    def run_merge(self):
        merger.merge(self.managed, self.target, self.state)

    def test_install_update_disable_preserves_personal_settings(self):
        personal = {"model": "example-model", "projects": {"/example": {"trust_level": "trusted"}},
                    "mcp_servers": {"personal": {"command": "/example/bin/server"}}}
        self.target.write_text(tomli_w.dumps(personal))
        self.desired({"docs": self.old})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target)["mcp_servers"]["docs"], self.old)
        first = self.target.read_bytes()
        self.run_merge()
        self.assertEqual(self.target.read_bytes(), first)
        self.desired({"docs": self.new})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target)["mcp_servers"]["docs"], self.new)
        self.desired({})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), personal)
        self.assertEqual(json.loads(self.state.read_text())["owned"], {})

    def test_inactive_fresh_integration_writes_nothing(self):
        self.desired({})
        self.run_merge()
        self.assertFalse(self.target.exists())
        self.assertFalse(self.state.exists())

    def test_disabled_unowned_external_config_is_not_parsed(self):
        self.target.write_text("[invalid external config")
        self.desired({})
        self.run_merge()
        self.assertEqual(self.target.read_text(), "[invalid external config")
        self.assertFalse(self.state.exists())

    def test_conflicting_new_entry_fails_without_writes(self):
        self.target.write_text(tomli_w.dumps({"mcp_servers": {"docs": self.old}}))
        before = self.target.read_bytes()
        self.desired({"docs": self.new})
        with self.assertRaisesRegex(ValueError, "conflicts"):
            self.run_merge()
        self.assertEqual(self.target.read_bytes(), before)
        self.assertFalse(self.state.exists())

    def test_edited_owned_entry_is_not_overwritten_or_removed(self):
        self.desired({"docs": self.old})
        self.run_merge()
        self.target.write_text(tomli_w.dumps({"mcp_servers": {"docs": self.new}}))
        before = self.target.read_bytes()
        state = self.state.read_bytes()
        self.desired({})
        with self.assertRaisesRegex(ValueError, "conflicts"):
            self.run_merge()
        self.assertEqual(self.target.read_bytes(), before)
        self.assertEqual(self.state.read_bytes(), state)

    def test_deleted_owned_entry_can_be_disabled(self):
        self.desired({"docs": self.old})
        self.run_merge()
        self.target.write_text('model = "example"\n')
        self.desired({})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), {"model": "example"})

    def test_legacy_adoption_uses_previous_generation_and_detects_edits(self):
        self.target.write_text(tomli_w.dumps({"mcp_servers": {"docs": self.old}}))
        self.desired({})
        with patch.object(merger, "legacy_owned", return_value={"docs": self.old}):
            self.run_merge()
        self.assertNotIn("mcp_servers", merger.load_toml(self.target))
        self.state.unlink()
        self.target.write_text(tomli_w.dumps({"mcp_servers": {"docs": self.new}}))
        with patch.object(merger, "legacy_owned", return_value={"docs": self.old}):
            with self.assertRaisesRegex(ValueError, "conflicts"):
                self.run_merge()

    def test_legacy_activation_parser_rejects_new_hook(self):
        settings = "/nix/store/00000000000000000000000000000000-codex-managed-settings"
        hook = ('run /nix/store/example-python-env/bin/python3 '
                '/nix/store/example-codex-merge-config.py \\\n'
                f'  {settings} "$HOME/.codex/config.toml"\n')
        with patch.object(Path, "is_file", return_value=True), \
             patch.object(Path, "read_text", return_value=hook), \
             patch.object(merger, "load_toml", return_value={"mcp_servers": {"docs": self.old}}) as load:
            self.assertEqual(merger.legacy_owned("/nix/store/example-generation/activate"), {"docs": self.old})
            load.assert_called_once_with(settings)
        with patch.object(Path, "is_file", return_value=True), \
             patch.object(Path, "read_text", return_value=hook.rstrip() + ' \\\n  --state /example/state\n'):
            self.assertEqual(merger.legacy_owned("/nix/store/example-generation/activate"), {})
        self.assertEqual(merger.legacy_owned("/tmp/untrusted-activation"), {})

    def test_legacy_symlink_becomes_writable_without_changing_source(self):
        source = self.root / "store-config"
        source.write_text('model = "example"\n')
        source.chmod(0o444)
        self.target.symlink_to(source)
        self.desired({"docs": self.old})
        self.run_merge()
        self.assertFalse(self.target.is_symlink())
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(source.read_text(), 'model = "example"\n')

    def test_interrupted_updates_recover_even_when_desired_changes_again(self):
        self.desired({"docs": self.old})
        self.run_merge()
        self.desired({"docs": self.new})
        atomic = merger.atomic_write
        calls = 0

        def fail_final_write(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise OSError("simulated interruption")
            return atomic(*args, **kwargs)

        with patch.object(merger, "atomic_write", side_effect=fail_final_write):
            with self.assertRaises(OSError):
                self.run_merge()
        self.assertEqual(merger.load_toml(self.target)["mcp_servers"]["docs"], self.new)
        self.desired({})
        calls = 0

        def fail_config_write(*args, **kwargs):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("second interruption")
            return atomic(*args, **kwargs)

        with patch.object(merger, "atomic_write", side_effect=fail_config_write):
            with self.assertRaises(OSError):
                self.run_merge()
        self.run_merge()
        self.assertNotIn("mcp_servers", merger.load_toml(self.target))

    def test_invalid_toml_and_journal_are_not_replaced(self):
        self.desired({"docs": self.old})
        self.target.write_text("[broken")
        with self.assertRaises(ValueError):
            self.run_merge()
        self.assertEqual(self.target.read_text(), "[broken")
        self.target.write_text("")
        self.state.write_text("not json")
        with self.assertRaises(ValueError):
            self.run_merge()
        self.assertEqual(self.state.read_text(), "not json")


if __name__ == "__main__":
    unittest.main()
