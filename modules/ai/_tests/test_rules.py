"""Rules removal must preserve personal text, including whitespace."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).parent.parent / "_files/merge-rules-block"
BEGIN = '<!-- BEGIN nix-darwin managed rules -- do not edit between the markers -->'
END = '<!-- END nix-darwin managed rules -->'


class RulesTests(unittest.TestCase):
    def test_remove_and_repeat_preserve_surrounding_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'AGENTS.md'
            before, after = 'Personal note\n\n', '\nAnother note\n\n'
            target.write_text(f'{before}{BEGIN}\nManaged rule\n{END}\n{after}')
            for _ in range(2):
                subprocess.run(['zsh', str(SCRIPT), '--remove', str(target)], check=True)
                self.assertEqual(target.read_text(), before + after)

    def test_missing_file_stays_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'missing' / 'AGENTS.md'
            subprocess.run(['zsh', str(SCRIPT), '--remove', str(target)], check=True)
            self.assertFalse(target.parent.exists())

    def test_unterminated_marker_fails_without_changing_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'AGENTS.md'
            text = f'Personal note\n{BEGIN}\nUnclear ownership\n'
            target.write_text(text)
            result = subprocess.run(['zsh', str(SCRIPT), '--remove', str(target)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_text(), text)


if __name__ == '__main__':
    unittest.main()
