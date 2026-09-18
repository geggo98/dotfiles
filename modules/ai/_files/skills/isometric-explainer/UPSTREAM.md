# Upstream

This skill is vendored, not authored here.

| Field | Value |
|---|---|
| Source | https://github.com/LaurentiuGabriel/learnscape/tree/main/skills/isometric-explainer |
| Upstream commit | `5c8af77808ba11bff6f4b46297dc45514247c4a5` |
| Vendored at | 2026-09-18 |
| License | MIT (see `LICENSE` in this directory — the repo root's CC0 does not extend here) |

The technique behind this skill, and the two reference implementations it
generalizes (TokenTown, a transformer laid out as a city; EngineWorks, an F1
power unit as a factory line), are described by the author in
[How I use LLMs to learn complex topics](https://laurentiugabriel.github.io/blog/articles/how-i-use-llms-to-learn/)
(Laurentiu Raducu, 2026-08-09).

## Local changes

None yet — this commit vendors the skill unchanged, byte-for-byte.

## Re-syncing with upstream

```bash
sha=<new upstream commit>
scratch=$(mktemp -d) && cd "$scratch"
gh api "repos/LaurentiuGabriel/learnscape/tarball/${sha}" > t.tar.gz
tar xzf t.tar.gz
diff -ru */skills/isometric-explainer/assets \
        ~/.config/nix-darwin/modules/ai/_files/skills/isometric-explainer/assets
```

`assets/template/` should diff clean or near-clean (it is meant to stay
byte-identical). `SKILL.md` and `references/` will differ everywhere once
local changes land here — read the upstream diff for *new* rules or fixed
bugs, and fold those in by hand rather than overwriting the local file.
