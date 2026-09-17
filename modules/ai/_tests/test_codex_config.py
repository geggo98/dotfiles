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

    def desired(self, servers, status_line=None, model=None,
                reasoning_effort=None, plan_reasoning_effort=None,
                reasoning_effort_override=None):
        managed = {"mcp_servers": servers}
        if status_line is not None:
            managed["tui"] = {"status_line": status_line}
        if model is not None:
            managed["model"] = model
        if reasoning_effort is not None:
            managed["model_reasoning_effort"] = reasoning_effort
        if plan_reasoning_effort is not None:
            managed["plan_mode_reasoning_effort"] = plan_reasoning_effort
        # `is not None`, never truthiness: False is a value this option
        # manages, and the whole default depends on it being written.
        if reasoning_effort_override is not None:
            managed["features"] = {"reasoning_effort_override": reasoning_effort_override}
        self.managed.write_text(tomli_w.dumps(managed))

    def run_merge(self):
        merger.merge(self.managed, self.target, self.state)

    def test_disable_devenv_preserves_other_servers_and_personal_settings(self):
        devenv = {"command": "/example/bin/+mcp-devenv", "args": []}
        personal = {"url": "https://personal.example.org/mcp"}
        self.target.write_text(tomli_w.dumps({"model": "example", "mcp_servers": {"personal": personal}}))
        self.desired({"devenv": devenv, "docs": self.old})
        self.run_merge()
        self.desired({"docs": self.old})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), {
            "model": "example", "mcp_servers": {"personal": personal, "docs": self.old},
        })
        self.assertNotIn("devenv", json.loads(self.state.read_text())["owned"])

    def test_status_line_install_update_override_and_disable(self):
        personal = {"model": "example", "tui": {"theme": "example"},
                    "projects": {"/example": {"trust_level": "trusted"}}}
        self.target.write_text(tomli_w.dumps(personal))
        # Existing MCP-only version-1 journal needs no separate migration.
        self.state.write_text(json.dumps({"version": 1, "owned": {}}))
        for status_line in (["run-state"], ["model-with-reasoning"], []):
            self.desired({}, status_line)
            self.run_merge()
            expected = {**personal, "tui": {**personal["tui"], "status_line": status_line}}
            self.assertEqual(merger.load_toml(self.target), expected)
            first = self.target.read_bytes()
            self.run_merge()
            self.assertEqual(self.target.read_bytes(), first)
            expected["tui"]["status_line"] = ["current-dir"]
            self.target.write_text(tomli_w.dumps(expected))
            self.run_merge()
            self.assertEqual(self.target.read_bytes(), first)
        self.desired({})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), personal)
        self.assertIsNone(json.loads(self.state.read_text())["owned_status_line"])

    def test_status_line_disable_preserves_personal_edits(self):
        self.desired({}, ["run-state"])
        self.run_merge()
        personal = {"tui": {"status_line": ["current-dir"]}}
        self.target.write_text(tomli_w.dumps(personal))
        self.desired({})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), personal)
        self.assertIsNone(json.loads(self.state.read_text())["owned_status_line"])

    def test_status_line_interruption_then_disable(self):
        for fail_at in (1, 2, 3):
            with self.subTest(fail_at=fail_at):
                self.target.unlink(missing_ok=True)
                self.state.unlink(missing_ok=True)
                self.desired({}, ["run-state"])
                self.run_merge()
                self.desired({}, ["current-dir"])
                atomic = merger.atomic_write
                calls = 0

                def interrupt(*args, **kwargs):
                    nonlocal calls
                    calls += 1
                    if calls == fail_at:
                        raise OSError("simulated interruption")
                    return atomic(*args, **kwargs)

                with patch.object(merger, "atomic_write", side_effect=interrupt):
                    with self.assertRaises(OSError):
                        self.run_merge()
                self.desired({})
                self.run_merge()
                self.assertEqual(merger.load_toml(self.target), {})

    def test_status_line_does_not_bypass_mcp_conflict(self):
        self.target.write_text(tomli_w.dumps({"mcp_servers": {"docs": self.old}}))
        before = self.target.read_bytes()
        self.desired({"docs": self.new}, ["run-state"])
        with self.assertRaisesRegex(ValueError, "conflicts"):
            self.run_merge()
        self.assertEqual(self.target.read_bytes(), before)
        self.assertFalse(self.state.exists())

    def test_invalid_tui_or_status_journal_fails_before_writing(self):
        self.desired({}, ["run-state"])
        for config, state in (
            ({"tui": "invalid"}, {"version": 1, "owned": {}}),
            ({}, {"version": 1, "owned": {}, "owned_status_line": "invalid"}),
        ):
            with self.subTest(config=config, state=state):
                self.target.write_text(tomli_w.dumps(config))
                self.state.write_text(json.dumps(state))
                before = self.target.read_bytes(), self.state.read_bytes()
                with self.assertRaises(ValueError):
                    self.run_merge()
                self.assertEqual((self.target.read_bytes(), self.state.read_bytes()), before)

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

    # -- Scalar leaves (model, and by construction model_reasoning_effort /
    # plan_mode_reasoning_effort): same LEAVES mechanism as status_line above,
    # exercised through "model" as the representative leaf.

    def test_model_install_update_override_and_disable(self):
        personal = {"model_reasoning_effort": "medium",
                    "projects": {"/example": {"trust_level": "trusted"}}}
        self.target.write_text(tomli_w.dumps(personal))
        # Existing MCP-only version-1 journal needs no separate migration.
        self.state.write_text(json.dumps({"version": 1, "owned": {}}))
        self.desired({}, model="gpt-5.6-terra")
        self.run_merge()
        expected = {**personal, "model": "gpt-5.6-terra"}
        self.assertEqual(merger.load_toml(self.target), expected)
        first = self.target.read_bytes()
        self.run_merge()
        self.assertEqual(self.target.read_bytes(), first)
        self.target.write_text(tomli_w.dumps({**expected, "model": "picked-by-codex"}))
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), expected)
        self.desired({})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), personal)
        self.assertIsNone(json.loads(self.state.read_text())["owned_model"])

    def test_model_disable_preserves_personal_edits(self):
        self.desired({}, model="gpt-5.6-terra")
        self.run_merge()
        personal = {"model": "gpt-6-astra"}
        self.target.write_text(tomli_w.dumps(personal))
        self.desired({})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), personal)
        self.assertIsNone(json.loads(self.state.read_text())["owned_model"])

    def test_model_overwrites_preexisting_value_without_conflict(self):
        # The real state of a machine that has used Codex's own /model picker
        # before this leaf was ever Nix-managed: unlike mcp_servers, this must
        # not raise -- the whole point is that activation replaces it.
        self.target.write_text(tomli_w.dumps({
            "model": "gpt-6-astra", "model_reasoning_effort": "medium",
        }))
        self.state.write_text(json.dumps({"version": 1, "owned": {}, "owned_status_line": None}))
        self.desired({}, model="gpt-5.6-terra")
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), {
            "model": "gpt-5.6-terra", "model_reasoning_effort": "medium",
        })
        self.assertEqual(json.loads(self.state.read_text())["owned_model"], "gpt-5.6-terra")

    def test_model_disable_leaves_empty_config(self):
        self.desired({}, model="gpt-5.6-terra")
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), {"model": "gpt-5.6-terra"})
        self.desired({})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), {})
        self.assertTrue(self.target.exists())

    def test_model_interruption_then_disable(self):
        for fail_at in (1, 2, 3):
            with self.subTest(fail_at=fail_at):
                self.target.unlink(missing_ok=True)
                self.state.unlink(missing_ok=True)
                self.desired({}, model="gpt-5.6-terra")
                self.run_merge()
                self.desired({}, model="gpt-6-astra")
                atomic = merger.atomic_write
                calls = 0

                def interrupt(*args, **kwargs):
                    nonlocal calls
                    calls += 1
                    if calls == fail_at:
                        raise OSError("simulated interruption")
                    return atomic(*args, **kwargs)

                with patch.object(merger, "atomic_write", side_effect=interrupt):
                    with self.assertRaises(OSError):
                        self.run_merge()
                self.desired({})
                self.run_merge()
                self.assertEqual(merger.load_toml(self.target), {})

    def test_invalid_model_journal_fails_before_writing(self):
        self.desired({}, model="gpt-5.6-terra")
        for state in (
            {"version": 1, "owned": {}, "owned_model": 5},
            {"version": 1, "owned": {}, "pending_model": ["a"]},
        ):
            with self.subTest(state=state):
                self.target.write_text(tomli_w.dumps({}))
                self.state.write_text(json.dumps(state))
                before = self.target.read_bytes(), self.state.read_bytes()
                with self.assertRaises(ValueError):
                    self.run_merge()
                self.assertEqual((self.target.read_bytes(), self.state.read_bytes()), before)

    def test_non_string_personal_model_is_replaced_not_rejected(self):
        self.target.write_text(tomli_w.dumps({"model": 42}))
        self.desired({}, model="gpt-5.6-terra")
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), {"model": "gpt-5.6-terra"})

        self.target.write_text(tomli_w.dumps({"model": 42}))
        self.state.write_text(json.dumps({"version": 1, "owned": {}}))
        self.desired({})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), {"model": 42})

    def test_model_and_status_line_are_managed_independently(self):
        self.desired({}, status_line=["run-state"], model="gpt-5.6-terra")
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), {
            "model": "gpt-5.6-terra", "tui": {"status_line": ["run-state"]},
        })
        self.desired({}, status_line=["run-state"])
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), {"tui": {"status_line": ["run-state"]}})
        journal = json.loads(self.state.read_text())
        self.assertIsNone(journal["owned_model"])
        self.assertEqual(journal["owned_status_line"], ["run-state"])

    def test_model_does_not_bypass_mcp_conflict(self):
        self.target.write_text(tomli_w.dumps({"mcp_servers": {"docs": self.old}}))
        before = self.target.read_bytes()
        self.desired({"docs": self.new}, model="gpt-5.6-terra")
        with self.assertRaisesRegex(ValueError, "conflicts"):
            self.run_merge()
        self.assertEqual(self.target.read_bytes(), before)
        self.assertFalse(self.state.exists())

    # -- Boolean leaf (features.reasoning_effort_override): a depth-2 leaf like
    # status_line, but with False as a MANAGED value rather than "unmanaged".
    # Every guard in the merge tests `is not None`; a truthiness test anywhere
    # would silently degrade the default to unmanaged, and these pin that.

    def test_reasoning_effort_override_install_update_override_and_disable(self):
        # [features] with personal siblings is the real shape on this machine.
        personal = {"model": "example", "features": {"memories": True},
                    "projects": {"/example": {"trust_level": "trusted"}}}
        self.target.write_text(tomli_w.dumps(personal))
        # Existing MCP-only version-1 journal needs no separate migration.
        self.state.write_text(json.dumps({"version": 1, "owned": {}}))
        for value in (False, True, False):
            self.desired({}, reasoning_effort_override=value)
            self.run_merge()
            expected = {**personal, "features": {
                **personal["features"], "reasoning_effort_override": value}}
            self.assertEqual(merger.load_toml(self.target), expected)
            first = self.target.read_bytes()
            self.run_merge()
            self.assertEqual(self.target.read_bytes(), first)
            expected["features"]["reasoning_effort_override"] = not value
            self.target.write_text(tomli_w.dumps(expected))
            self.run_merge()
            self.assertEqual(self.target.read_bytes(), first)
        self.desired({})
        self.run_merge()
        # Personal [features] keys survive; only our key is retracted.
        self.assertEqual(merger.load_toml(self.target), personal)
        self.assertIsNone(
            json.loads(self.state.read_text())["owned_reasoning_effort_override"])

    def test_reasoning_effort_override_disable_prunes_empty_features_table(self):
        # Round trip through an otherwise absent [features]: a typo in the
        # LEAVES path tuple fails here and nowhere else.
        self.desired({}, reasoning_effort_override=False)
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target),
                          {"features": {"reasoning_effort_override": False}})
        self.desired({})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), {})
        self.assertTrue(self.target.exists())

    def test_reasoning_effort_override_false_is_managed_not_unmanaged(self):
        # The shipped default is False. It must overwrite a pre-existing True
        # without conflict and be journalled as owned, exactly like a string.
        self.target.write_text(tomli_w.dumps({"features": {"reasoning_effort_override": True}}))
        self.state.write_text(json.dumps({"version": 1, "owned": {}, "owned_status_line": None}))
        self.desired({}, reasoning_effort_override=False)
        self.run_merge()
        self.assertIs(
            merger.load_toml(self.target)["features"]["reasoning_effort_override"], False)
        self.assertIs(
            json.loads(self.state.read_text())["owned_reasoning_effort_override"], False)

    def test_reasoning_effort_override_disable_preserves_personal_edits(self):
        self.desired({}, reasoning_effort_override=False)
        self.run_merge()
        personal = {"features": {"reasoning_effort_override": True}}
        self.target.write_text(tomli_w.dumps(personal))
        self.desired({})
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target), personal)
        self.assertIsNone(
            json.loads(self.state.read_text())["owned_reasoning_effort_override"])

    def test_invalid_reasoning_effort_override_journal_fails_before_writing(self):
        # 1 and "true" are what a lazy isinstance(v, (bool, int)) would admit.
        self.desired({}, reasoning_effort_override=False)
        for state in (
            {"version": 1, "owned": {}, "owned_reasoning_effort_override": 1},
            {"version": 1, "owned": {}, "pending_reasoning_effort_override": "true"},
        ):
            with self.subTest(state=state):
                self.target.write_text(tomli_w.dumps({}))
                self.state.write_text(json.dumps(state))
                before = self.target.read_bytes(), self.state.read_bytes()
                with self.assertRaises(ValueError):
                    self.run_merge()
                self.assertEqual((self.target.read_bytes(), self.state.read_bytes()), before)

    def test_non_bool_personal_override_is_replaced_not_rejected(self):
        # The on-disk config is never type-validated by design; the leaf still
        # overwrites authoritatively whatever type it finds.
        self.target.write_text(tomli_w.dumps({"features": {"reasoning_effort_override": "yes"}}))
        self.desired({}, reasoning_effort_override=False)
        self.run_merge()
        self.assertEqual(merger.load_toml(self.target),
                          {"features": {"reasoning_effort_override": False}})


if __name__ == "__main__":
    unittest.main()
