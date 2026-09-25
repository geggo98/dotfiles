# VUKFZIF — Workflow, Transition IDs, Conventions

Encapsulated project knowledge for the `jira` skill. Captured by read-only discovery
against the `/transitions` endpoint (snapshot: 2026-06-22, ticket JIRA-3052).

## Statuses & transition IDs

The VUKFZIF workflow uses **global "Any status" transitions** (marked ⚡ "Any" in the
workflow editor): every transition is named exactly like its target status, **none** has
a screen or required field, and **the same transition id is reachable from every status**.
That is precisely what makes arbitrary status changes trivial — one id per target status
is enough.

| Target status     | Transition ID | Status ID | Category    |
| ----------------- | ------------- | --------- | ----------- |
| Open              | 101           | 1         | To Do       |
| Backlog           | 91            | 10109     | To Do       |
| To Do             | 11            | 10083     | To Do       |
| In Progress       | 21            | 3         | In Progress |
| In Code Review    | 61            | 10084     | In Progress |
| In QA             | 71            | 10091     | In Progress |
| In Test PM        | 111           | 10092     | In Progress |
| Ready for Release | 81            | 10089     | In Progress |
| Done              | 31            | 10085     | Done        |
| Closed            | 121           | 6         | Done        |

**`In Review`** appears in the workflow diagram as a separate, greyed-out status but is
**decoupled**: no global transition leads to it and the `/transitions` endpoint does not
list it. The skill therefore does not offer it.

> This table is **documentation only** (a reference snapshot from the discovery date) — the
> client does not read it. At runtime `transition` always resolves the target status via the
> live `/transitions` endpoint (`select .to.name == <target>`) and aborts cleanly if the
> endpoint is unreachable (no blind POST of stale ids). Look it up fresh with
> `jira.sh transitions <KEY> --format tsv`.

## Issue types & hierarchy (measured 2026-09-25)

VUKFZIF has three issue types, no sub-tasks:

| Type | hierarchyLevel |
| --- | --- |
| Epic | 1 |
| Bug | 0 |
| Task | 0 |

An Epic needs nothing beyond `project`, `issuetype` and `summary` to create — there is no
separate "Epic Name" field on this site. The Epic Link custom field is gone from the create
and edit screens; the standard **`parent`** field is how a ticket attaches to an Epic, both
ways: `jira.sh --write create --type Epic --summary "…"` then `--write create --summary "…"
--parent EPIC-KEY` (or `--write edit KEY --parent EPIC-KEY` on an existing ticket). In JQL,
`parent = EPIC-KEY` and `"Epic Link" = EPIC-KEY` return the same tickets; `jira.sh epic
EPIC-KEY` uses `parent =`.

Two API quirks that only show up on the `parent` field, both worked around in the client
(`create --parent` and `edit` both read the result back rather than trust the response):

- Jira has answered a `parent` write with **HTTP 204** while silently not storing it
  ([JRACLOUD-78657](https://jira.atlassian.com/browse/JRACLOUD-78657), reported fixed).
- A **null** `parent` write (`edit --no-parent`) 500s on an issue that has no parent to
  remove — `edit` only sends it when a parent is actually set.

## Ordering link types (for `jira.sh epic`)

`jira.sh epic EPIC-KEY` sorts an Epic's children so a blocker/dependency always precedes
what needs it. Only these four of the site's link types carry a before/after meaning; the
rest (`Relates`, `Cloners`, `Connects`, `Contains`, …) are shown per ticket but never
reorder anything:

| Type | Reading that puts the SUBJECT first | Reading that puts the OBJECT first |
| --- | --- | --- |
| `Blocks` | "A blocks B" → A first | — |
| `Used` | "A Used by B" → A first | — |
| `Depends` | — | "A Depends on B" → B first |
| `Follows` | — | "A follows B" → B first |

## Issue creation — conventions (from real tickets, internal CVE runbook)

- **Issue type:** `Task`. **Label:** `security` (for CVE / security tickets).
- **Summary:** `[<repo-tag>] <severity> <short description>`. Observed tags:
  `[ServiceA]`, `[ServiceB]`, `[ServiceC]`, `[ServiceD]`, `[ServiceE]`, `[ServiceF]`, `[Gateway]`,
  generic `[Security]`. One ticket per repo.
- **Description:** affected packages, severity, advisory IDs with links; the last line is
  the attribution line (in wiki-markup for REST v2).
- **Project key:** `VUKFZIF` (client default `JIRA_PROJECT_KEY`).

## Attachments & embedding (REST v2)

- Upload: `POST /rest/api/2/issue/<KEY>/attachments` (multipart, `X-Atlassian-Token: no-check`).
  Client: `jira.sh --write attach <KEY> <file>…` or `--attach` / `--embed` on `comment` / `describe`.
- Reference in **v2 wiki-markup** (the file must already be attached): image `!name.png!`
  (inline, thumbnail `!name.png|thumbnail!`), otherwise `[^name.zip]` (file link, e.g. a
  crawllog ZIP). `--embed` generates the right reference automatically (image extension →
  `!…!`, otherwise → `[^…]`).
- `describe` **replaces** the description (no merge). The prior text is journaled, so
  `jira.sh --write undo` can restore it.

## Known assignees (aliases)

`jira.sh --write assign <KEY> <alias>` resolves these short names directly to an accountId:

| Alias   | Person                                             | accountId                                     |
| ------- | -------------------------------------------------- | --------------------------------------------- |
| `alex` | Alex Beispiel (`alex.beispiel@example.com`) | `712020:00000000-0000-4000-8000-000000000000` |

Any other email is resolved at runtime via `/user/search` (`jira.sh user <email>`, which is
cache-backed to avoid rate limiting on the large directory); `@me` takes the account behind
the token.

Marco is the current default for **automated CVE tickets** (transition to `In Code Review`
+ assignment). Assignees of other tickets vary — when in doubt, clarify with the user.

## Workflow diagram (usual reading order)

```text
START → Create → Open → Backlog → To Do → In Progress → In Code Review
        → In QA → In Test PM → Ready for Release → Done → Closed
        (In Review: decoupled, no transition)
```

Because every transition is global, this order is only the usual reading direction —
technically every status is directly reachable from every other.
