"""Shared secret masker for the stream-filtering tools (+errlog, +vault).

Imported as `masker` from the directory next to the script, which Python puts
on sys.path (symlinks resolved). Standard library only.
"""
import re
import urllib.parse

MASK = b"***"


def variants(raw):
    """raw, URL-encoded and URL-decoded form (same idea as the database skill's redact.pl)."""
    out = {raw, urllib.parse.unquote_to_bytes(raw), urllib.parse.quote_from_bytes(raw, safe="").encode()}
    return {v for v in out if v}


class Masker:
    """Replaces known secret values, and optionally everything matching a format.

    patterns: iterable of (full, partial) byte regexes. `full` matches a whole
    secret of that format (e.g. a Vault token nobody has stored yet); `partial`
    matches, anchored at the END of a chunk, any prefix of such a secret, so a
    chunk boundary inside one never lets half a token through.
    """

    def __init__(self, values, patterns=()):
        values = sorted({v for raw in values for v in variants(raw)}, key=lambda v: (-len(v), v))
        self.maxlen = max((len(v) for v in values), default=0)
        # every proper prefix of a secret: only a tail that is one of these can
        # still turn into a secret, so only that tail is ever held back
        self.prefixes = {v[:k] for v in values for k in range(1, len(v))}
        alts = [re.escape(v) for v in values] + [full for full, _ in patterns]
        self.rx = re.compile(b"|".join(alts)) if alts else None
        self.partials = [re.compile(partial + b"$") for _, partial in patterns]
        self.replacements = 0

    def __call__(self, data):
        if not self.rx:
            return data
        out, n = self.rx.subn(MASK, data)
        self.replacements += n
        return out

    def safe_cut(self, raw):
        """How many leading bytes of a partial line may be written now: all but a
        tail that could still be the start of a secret (usually nothing, so a
        message without newline is not held back), and never a cut through the
        middle of a match."""
        cut = len(raw)
        for k in range(min(self.maxlen - 1, len(raw)), 0, -1):
            if raw[-k:] in self.prefixes:
                cut = len(raw) - k
                break
        for prx in self.partials:
            m = prx.search(raw)
            if m and m.start() < cut:
                cut = m.start()
        if self.rx:
            for m in self.rx.finditer(raw):
                if m.start() < cut < m.end():
                    cut = m.start()
                    break
        return cut
