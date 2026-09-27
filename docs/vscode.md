# VS Code extensions

Moved out of `AGENTS.md` to stay under Codex's 32 KiB project-doc budget. AGENTS.md keeps a short pointer; this file has the full, unedited text.

### VS Code extensions

The **general** set — useful in any repository — is pinned in `modules/vscode.nix` and
comes from `nix-vscode-extensions`. Anything with a language toolchain behind it is
project-specific and belongs in that project's `.vscode/extensions.json`. The full
inventory, the per-extension reasoning and the removal candidates are in
**`modules/_files/vscode/EXTENSIONS.md`**; what follows is only what bites.

**Open VSX is not a faithful mirror, so the registry is chosen per extension.** Measured
2026-08-26 across both: Open VSX served `christian-kohler.path-intellisense` 2.8.0 (2022)
against the marketplace's 2.10.0, `yzhang.markdown-all-in-one` 3.6.2 against 3.6.3, and
answered **404** for `deerawan.vscode-dash` outright. Picking one registry for everything
pins stale versions with no error anywhere. Use the **`-release`** attribute sets, too:
the plain `open-vsx` and `vscode-marketplace` include pre-releases, which on GitLens
means `2026.8.251013` instead of `18.3.0`.

**The input's age IS the cooldown.** `nix-vscode-extensions` carries no version strings —
each daily revision pins whatever the registries served that day, so a revision N days
old pins extension versions at least N days old. Hence
`[cooldown.per_input] nix-vscode-extensions = 14` in `scripts/supply-chain.toml`, the
extension bar rather than the 5-day input default. There are no versions to bump by
hand; `just update` moves the whole set.

`[[extensions]]` in that manifest is the separate, stricter half: it asks whether each
extension still exists and whether the version is still listed — the withdrawal signal a
date cannot give. Be precise about its limit: it resolves its **own** candidate version
from the registry, not the one `nix-vscode-extensions` pins, so a clean run means "still
healthy upstream", not "the installed version is healthy".

**One extension skips the dated snapshot entirely.** `lucax88x.codeacejumper` is
hash-pinned straight from the VS Marketplace in `modules/vscode.nix`
(`vscode-utils.extensionFromVscodeMarketplace`), not consumed from `vsmp`/`ovsx` — its
upstream has carried an open "maintainer wanted" issue since 2022, and a takeover there
must not ride in silently on the next `just update`. `[[extensions]]`'s `pin` field
changes what "ok" means for that one row: the audit checks the FIXED pinned version
(still listed, still old enough) and adds a new finding, `PIN_BEHIND`, when upstream has
since published something newer — a nudge to review, not an automatic adoption. Full
audit trail: `modules/_files/vscode/EXTENSIONS.md`.

**VS Code itself deliberately stays on the Homebrew cask**, and `programs.vscode.package`
is `null` — a supported value, since the home-manager module gates `home.packages` on
`cfg.package != null` and takes the `.vscode` directory name from its caller, not from
the package. Three measurements argue against moving the editor into Nix: the cask serves
1.134.0 where nixpkgs 26.05 has 1.119.0 and unstable 1.133.0; `vscode` is in no binary
cache for aarch64-darwin because it is unfree; and it would therefore be built locally,
at which point the R2 `post-build-hook` would push Microsoft's non-redistributable build
into a world-readable bucket. The same reasoning excludes exactly one extension,
`ms-vscode-remote.remote-containers` — the only unfree one of the candidates. A licence
filter in the push hook is not an option: `meta.license` is eval-time data and is not
recorded in the store.

**The failure mode that looks like success.** home-manager symlinks each extension as
`~/.vscode/extensions/<publisher>.<name>`, without a version suffix; VS Code's own
installs carry one. Both can sit there at once, and VS Code loads the **higher version** —
so a leftover gallery copy silently wins and the Nix pin does nothing. That is why
`extensions.autoUpdate` and `extensions.autoCheckUpdates` are both off, why the migration
uninstalls the gallery copies first, and why the check after a switch is:

```bash
find ~/.vscode/extensions -maxdepth 1 -type l ! -name '.*' | wc -l   # expect 19
```

The `! -name '.*'` is load-bearing, not tidiness: `.nix-managed-extensions.json` — the
file whose change triggers the regeneration hook — is itself a symlink, so a plain
`-type l` counts 19 and the check fails on a correct machine. `!` rather than `-not`
because `!` is POSIX; both were verified against `/usr/bin/find`.

Use `find`, not `ls -l | grep -- '->'`. That pipeline reported **0** on a correctly
switched machine on 2026-08-26, because the interactive `ls` here renders symlinks with
`⇒` rather than `->` — a shell alias silently turned a passing check into a failing one.
`find -type l` depends on neither the alias nor the arrow, and every symlink at that
depth is a Nix one: VS Code's own installs are real directories.

**A planted symlink is not a loaded extension.** VS Code does not rescan its extension
directory — `extensions.json` is the authority, and a symlink appearing beside it changes
nothing. Measured 2026-08-26 right after a switch that planted all 16 correctly:
`code --list-extensions` listed **none** of them; deleting `extensions.json` and
re-running it listed all 16 at their pinned versions. home-manager ships an onChange hook
for exactly this, gated on `package != null` — so `package = null` switches it off.
`modules/_files/vscode/regenerate-extensions-json` replaces it, and is also on `PATH` as
`+vscode-regen-extensions`.

That script refuses rather than acting when `.obsolete` is non-empty, and the reason is
the nastier half of the same problem: uninstalling an extension only QUEUES its directory
for deletion, and a rescan run while the queue is full picks those directories up again.
Because they carry a version suffix and the Nix symlinks do not, the higher version wins.
Measured the same day: regenerating with 39 queued directories resurrected five
uninstalled extensions and pinned GitLens to the gallery's 19.0.1 over the pinned 18.3.0.
Only VS Code clears that queue, by starting once — which is why the script is on `PATH`
for a human to re-run.

Related, and the reason to check the directory rather than the exit code:
`code --uninstall-extension` reported `OK` for `jrebocho.vscode-random` while its
directory was neither deleted nor queued, and a later rescan registered it again.

**The mirror-image case: a window already open when the regen runs.** Same root cause
(a window's extension host reads `extensions.json` once, at its own startup, never
again), opposite timing — instead of a window that predates the extension, one that was
already running when `just switch` rewrote `extensions.json` underneath it. A window
whose extension host started before the rewrite will not see it — not even as an error,
the new extension simply never appears in that session's `exthost.log`. The regen script
now samples `pgrep -x Code` **before** touching `extensions.json` and prints a `NOTE:`
line if VS Code was already running, since this is invisible to the running window no
matter how correct the regeneration is. The fix is the same as the first case: reload
(`Cmd+Shift+P` → `Developer: Reload Window`) or quit and reopen.

**This was NOT what actually happened when `lucax88x.codeacejumper` first showed
`command '…' not found` on 2026-09-27**, which is worth recording precisely because the
symptom is identical and it cost a round of the wrong diagnosis: a genuinely fresh
window, started well after `extensions.json` was correct on disk, *still* didn't
activate it — and still without a single log line anywhere. The actual cause was
workspace trust, not staleness; see "It does not activate at all in an untrusted
workspace, silently" in `modules/_files/vscode/EXTENSIONS.md`. Both failure modes
produce the exact same symptom (present on disk, absent from every log, command not
found) — a fresh window ruling out staleness is what tells them apart.

`mutableExtensionsDir = true` keeps that directory real and writable, which is what lets
project-specific extensions be installed into it by hand. The alternative — a single
directory symlink — would make VS Code's own `extensions.json` unwritable.

#### settings.json is read-only, so anything that wants to write it loops forever

`programs.vscode` renders `~/Library/Application Support/Code/User/settings.json` as a
symlink into `/nix/store`. Every write therefore fails with `EACCES`, and nothing in the
UI says so beyond a toast — the evidence is one line in
`~/Library/Application Support/Code/logs/<session>/window1/renderer.log`:

```
[error] Unable to write file 'vscode-userdata:…/User/settings.json'
        (EntryWriteLocked (FileSystemError): EACCES: permission denied)
```

`keybindings.json` joined it as a second read-only symlink once
`profiles.default.keybindings` gained entries (added for `lucax88x.codeacejumper`'s
AceJump shortcuts). Same mechanism, same failure mode: rebinding a key in the Keyboard
Shortcuts UI fails silently, and the same `EACCES` line appears with `keybindings.json`
in place of `settings.json`. `just vscode-settings-check` watches both files.

**A setting whose TYPE changed upstream is the usual cause, and it is invisible in the
value.** Measured 2026-08-26 against VS Code 1.134.0: `extensions.autoUpdate` was written
here as `false`, which VS Code no longer accepts — it declares
`{ type: "string", enum: ["on", "off"] }` and registers a migration beside it that rewrites
`false` to `"off"`. That migration runs at **every** start, and its result can never be
saved, so it runs again next time. The value was not wrong in meaning, only in type, and a
diff of the two files showed exactly one differing key out of 41.

Two things follow. Audit the whole class rather than the one key: VS Code 1.134.0 registers
31 configuration migrations, and `extensions.autoUpdate` was the only one intersecting this
repo's settings — worth re-checking after a major version jump, by grepping
`registerConfigurationMigrations` in `workbench.desktop.main.js`. And use
`just vscode-settings-check`, which reads the newest log session for exactly these write
attempts. It deliberately reports "inconclusive" (exit 2) when that session predates the
last switch — it compares the session name against the `lstat` mtime of the settings
symlink, which home-manager re-creates on every activation — because "VS Code has not
started since" must never be reported as "clean".

**Settings Sync is the second writer, and it is a structural conflict, not an accident.**
Both Macs get `hm.vscode` from `modules/home-manager-base.nix`, and their two files cannot
be identical: `terminal.integrated.profiles.osx` embeds
`/etc/profiles/per-user/<username>/…`. Each side therefore wants to write the other's
values into a file it may not touch. Measured on the same day: 5 of 5 syncs failed, and
the last successfully applied state (`sync/settings/lastSyncsettings.json`) was months old
— frozen precisely because a failed write is never acknowledged.

The fix is to tell Sync that Nix owns these keys, generated rather than hand-listed:

```nix
userSettings = managedSettings // {
  "settingsSync.ignoredSettings" = builtins.attrNames
    (managedSettings // { "extensions.autoCheckUpdates" = false; });
};
```

Two details in those three lines. `extensions.autoCheckUpdates` is named explicitly
because home-manager merges it in **after** this attrset (out of
`enableExtensionUpdateCheck`), so `attrNames` cannot see it. And
`settingsSync.ignoredSettings` itself is deliberately absent from its own list: the
setting carries `disallowSyncIgnore`, VS Code filters it out at runtime anyway, and naming
it would show up as "Value is not accepted" against its own enum schema. Keys of
extensions that are not installed can draw the same cosmetic hint — they are still
honoured, because the list is evaluated as plain strings.

#### The `[Theme]`-scoped colour warnings are a VS Code bug, not a bad value

VS Code 1.134.0 marks **every** property inside the theme-scoped
`workbench.colorCustomizations` block with `Property editorBracketPairGuide.background1 is
not allowed.` The colours are applied regardless, and the colour ids are registered — the
schema is at fault. A `[Theme]` block is validated against
`{ $ref: "vscode://schemas/workbench-colors", additionalProperties: false }`, and the
bundled JSON language service now follows draft-2019-09 semantics, where a `$ref` no
longer contributes the `properties` annotation that `additionalProperties` consults (only
`unevaluatedProperties` would). Every property in the block is therefore rejected, while
the same keys one level up validate — top level has no `additionalProperties: false`
anywhere in its schema chain.

Upstream is [microsoft/vscode#328165](https://github.com/microsoft/vscode/issues/328165),
closed for 1.135.0. Do not silence it by dropping the `[Theme]` scoping: that would leak
this repo's cyberpunk bracket colours into every other theme, to fix a warning that the
next cask update removes.

