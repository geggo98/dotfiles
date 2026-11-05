# Risk checks for an extension that is not in recommended.md

`+vscode-ext scan` already refuses what is inside the cooldown or withdrawn. These checks
cover what a date cannot tell. Look at each, and say which ones fired.

| Signal | Why it matters | Where to look |
|---|---|---|
| Publisher domain **not verified** AND few installs (< ~100 k) | Cheap to impersonate, slow to be noticed | `scan` prints `UNVERIFIED publisher` and the install count |
| Last release **older than two years**, or the repository archived | Abandoned ids are the classic takeover target (an open "maintainer wanted" issue is the loud version of it) | Marketplace page, the source repo |
| Dormant for years, then **revived by new contributors** | The takeover pattern itself | the source repo's commit history |
| **Unfree licence** | Never builds through Nix (a local build would be pushed to the public cache); a runtime install is the user's call | licence field on the Marketplace page |
| Pulls in a **pack or dependency** | Each member is a separate trust decision; `scan` lists them as "pulled in" | `scan` output |
| **Downloads a binary at runtime** (language server, JDK) | Outside the cooldown and outside the checksum `+vscode-ext` verifies | extension README, source |
| Activates on **`*`** (every start) | Runs in every window of that profile | `activationEvents` in `package.json` |
| Asks for **credentials in settings.json** | settings.json is a Nix store file here and may be in a public repo | extension README |
| Writes **decrypted secrets next to the encrypted file** | Lands in the working tree and in agent context | see `signageos.signageos-vscode-sops` in recommended.md |
| Name **one edit away** from a well-known extension | Typosquats | compare with the id the user meant |
| A **fork** recommended as a replacement for a dead extension | Same takeover pattern, one step removed | read its history before trusting it |

If two or more fire, or one fires and the extension runs code from the repo being
edited (a debugger, a test runner, a build integration), say so and let the user decide.
Say so *before* installing, not after.

Language servers and formatters that an extension would otherwise download can usually be
pointed at a Nix-provided binary through a setting; `modules/vscode.nix` does this for
shellcheck, shfmt, lua-language-server and ltex-ls-plus. Mention it when a profile needs
one that is not covered.
