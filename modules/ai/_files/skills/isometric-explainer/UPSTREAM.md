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

- `scripts/smoke.mjs` (plain Node + an unpinned `playwright` resolved from the
  tested project's `node_modules`) was replaced with `scripts/smoke.ts` +
  `scripts/smoke.sh`, a deno port pinned the same way as
  `../slidev/scripts/check-slide-overflow.{sh,ts,lock}` — deployed skill files
  live read-only in `/nix/store`, so a script cannot `npm install` next to
  itself. Behavior is unchanged (verified against the template: same eight
  stations, same PASS); the CWD-relative `createRequire` fallback for locating
  `playwright` is gone because nothing needs it anymore.
- `SKILL.md` and `references/narration.md` gained pointers to the sibling
  `Skill(technical-writing)` and `Skill(slidev)` skills and to the
  (not-vendored) `text-to-3d-asset` skill by the same author, a `## Where this
  came from` section, and the `metadata:` block above. A close read against
  `Skill(technical-writing)` found the upstream prose already at a high bar —
  no AI-writing tells, no needless words, active voice throughout — so beyond
  those additions the only other change is fixing two now-stale
  `scripts/smoke.mjs` mentions to `scripts/smoke.sh`
  (`references/checklist.md`) and one tightened sentence
  (`references/isometric-drawing.md`, "shed represents" → "shed stands for").
  The `description:` frontmatter field (it controls auto-triggering) and
  everything under `assets/template/` are untouched, byte-for-byte from
  upstream.

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
byte-identical). `SKILL.md` and `references/` will differ everywhere because
of the local additions above — read the upstream diff for *new* rules or fixed
bugs, and fold those in by hand rather than overwriting the local file. If
upstream's `scripts/smoke.mjs` changed behavior (not just style), port the
change into `scripts/smoke.ts` by hand; there is no automated diff for it
since the local file is a different language.
