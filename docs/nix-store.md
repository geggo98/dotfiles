# Store deduplication: auto-optimise-store and the weekly nix-optimise pass

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

**Changing `auto-optimise-store` needs one `just daemon-restart`.** It is a daemon-side
setting, and Determinate's `nix-daemon` reads `/etc/nix/nix.custom.conf` only at startup —
the same trap as the `post-build-hook` string, and `darwin-rebuild switch` does not restart
it. Measured 02.09.2026, after a switch that wrote `auto-optimise-store = false` on a
daemon started three hours earlier: a fresh build of a derivation containing two identical
files still yielded a single inode with `nlink=3`. **`nix config show` is not evidence** —
the client parses the files itself and reports `false` while the daemon is still
deduplicating. Test it the way that cannot lie:

```bash
# two identical files in one output; nlink >= 2 means the daemon is still optimising
nix build --no-link --print-out-paths -f probe.nix   # derivation writing $out/a and $out/b
perl -e 'printf "%s nlink=%d\n", $_, (stat)[3] for @ARGV' "$out/a" "$out/b"
```

`modules/nix-gc.nix` carries a second weekly daemon, `nix-optimise`, an hour after
the GC. Store deduplication used to happen inline via `auto-optimise-store = true`
and was moved off the write path because it hard-links every new file against
`/nix/store/.links` under a global lock — measured 02.09.2026 on this machine, same
derivation of 4000 small files, two runs each: **58.8 s / 58.0 s with it against
14.0 s / 13.1 s without, i.e. 4.3x**, with 675_925 links already in that directory.
The saving it produces is real and is kept (`nix-collect-garbage` reported "hard
linking is currently saving 5.3 GiB" right after the change), it is simply
collected weekly instead of on every store write. The cost grows with the link
count, so re-measure rather than assume on a machine with a younger store.

