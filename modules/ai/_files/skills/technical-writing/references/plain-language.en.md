# Plain Language for IT Texts

This reference applies the four plain-language principles of ISO 24495-1:2023 to
everyday IT writing: Jira tickets, PR descriptions, review comments, runbooks,
READMEs, and error messages. Load it before writing or reviewing any of those.

> Attribution: adapted for IT writing from ISO 24495-1:2023, *Plain language —
> Part 1: Governing principles and guidelines*. This file is an adaptation with
> original wording and original examples, not a reproduction of the standard's
> text. For the normative text, consult the standard itself.

A text works when readers get what they need (relevant), can find it
(findable), can understand it (understandable), and can act on it (usable).
The fourth principle checks the other three against real readers.

---

## Principle 1: Readers get what they need (ISO 5.1)

Decide who reads the text and what they need from it before you draft
(ISO 5.1.1). Most IT writing fails here, not at the sentence level.

### Identify the readers (ISO 5.1.2)

Name the concrete readers and their knowledge level: the PR reviewer, the
future maintainer who inherits the code, the on-call engineer at 3 a.m., the
PM who plans the sprint from the Jira ticket. Write for the one who knows
least among those who must act.

Bad (runbook step):
> Restart the usual suspects and clear the cache like last time.

Good:
> Restart both payment services:
> `kubectl rollout restart deploy/payment-gateway deploy/ledger-sync -n payments`
> Then flush the rate-limit cache: `redis-cli -n 2 FLUSHDB`

### Identify the readers' purpose (ISO 5.1.3)

Ask what the reader will do with the text: approve the PR, reproduce the bug,
estimate the work, recover the service. Give them exactly what that action
requires.

Bad (bug ticket):
> Login is broken again for some users.

Good:
> Login fails with HTTP 500 for SSO users since release 2026-08-03.
> Reproduce: 1. Log out. 2. Choose "Company SSO". 3. The error appears after
> the IdP redirect. Non-SSO login works.

### Identify the reading context (ISO 5.1.4)

Consider where and under what pressure the text gets read. A reviewer skims
the description next to a 40-file diff. On-call reads the runbook
mid-incident, tired. Nobody reads prose under pressure; front-load commands.

Bad (runbook opening):
> This service dates back to the 2024 cluster migration, which explains some
> of the unusual path layout described below...

Good:
> Symptom: checkout p99 latency above 2 s.
> First check: queue depth. Run `rabbitmqadmin list queues name messages`.
> If `orders` exceeds 10 000, continue with "Drain and scale" below.

### Pick the document type that fits (ISO 5.1.5)

Choose the medium the reader will find later. Decisions belong in an ADR or
the docs, not in a Slack thread or a comment on a closed PR. A 40-line
"future improvement" review comment belongs in a follow-up ticket.

Bad: explaining the new retry policy in a reply on a merged PR.

Good: add it to `docs/runbooks/payments.md`, link that from the reply, and
file a ticket for the open question.

### Select only content readers need (ISO 5.1.6 a-e)

Put the readers' questions first, answer them, and cut the rest. Do not
restate what the artifact already shows: the diff shows *what* changed, so
the PR description explains *why* and *what to watch out for*.

Bad (PR description):
> Changed line 42 in UserService.java, added an import in OrderController,
> renamed `tmp` to `tmpUser`, updated three tests.

Good:
> Cache user lookups per request. The N+1 query on /orders came from repeated
> `findUser` calls inside the serializer. Watch out for: the cache is
> request-scoped, so background jobs still hit the DB per call.

### Select content ethically (ISO 5.1.6 f)

State accurate facts. Do not hide known limitations, risks, or behavior
changes to smooth the review; an approval earned that way is void.

Bad (PR description, while line amounts actually round differently now):
> Pure refactor of the billing module. No functional changes.

Good:
> Refactor of the billing module. One behavior change: line amounts now round
> half-up instead of half-even. Invoices before 2026 are not backfilled.
> Known limitation: the PDF export still shows the old rounding.

---

## Principle 2: Readers can easily find what they need (ISO 5.2)

Structure and layout decide whether a reader finds the answer in ten seconds
or gives up (ISO 5.2.1).

### Lead with the most important message (ISO 5.2.2 a)

Put the core message where every reader sees it: at the top. This is the
TL;DR rule. Jira tickets, PR descriptions, and review comments start with a
TL;DR of one to three sentences: problem, impact, ask. Details follow below.

Bad (PR description opening):
> Some background first. Our deployment pipeline has grown over the years and
> several stages were added for reasons that are partly historical...

Good:
> TL;DR: Split the deploy job into build and release stages. Pipeline time
> drops from 22 to 9 minutes. No config changes needed for other teams.
>
> Background: ...

### Group related information, build on the known (ISO 5.2.2, 5.2.2 b)

Keep everything about one topic in one place. Introduce new concepts by
connecting them to what the reader already knows.

Bad (ticket): acceptance criteria spread across the description, comment 3,
and comment 7.

Good: one "Acceptance criteria" section in the description, updated in place.

### Order procedures chronologically (ISO 5.2.2 c)

Write steps in the order the reader executes them. Never bury a prerequisite
inside a later step.

Bad (runbook):
> Run the migration (after stopping the workers, which requires draining the
> queue first).

Good:
> 1. Drain the queue: `just drain orders`
> 2. Stop the workers: `just stop workers`
> 3. Run the migration: `just migrate`

### Put what most readers need first (ISO 5.2.2 d)

Order sections by audience size. In a README, install-and-run comes before
build-from-source; most readers install, few build.

Bad: README opens with cross-compiling notes; `npm install` sits in section 6.

Good: README opens with install and first use; building from source moves to
the end.

### Place warnings before the instructions they guard (ISO 5.2.2 e)

If a step can cause damage, warn before the step, never after. A reader
executing step by step has already run the command when the note arrives.

Bad (runbook):
> Run `terraform apply`. Note: never do this without the state lock; a
> concurrent apply corrupts the state.

Good:
> Warning: acquire the state lock first (`just lock prod`). A concurrent
> apply corrupts the state.
> Then run `terraform apply`.

### Use information design: prominence, proximity, similarity (ISO 5.2.3)

Make structure visible. In Markdown that means:

- Prominence: headings for sections; bold for the one critical warning, not
  for decoration.
- Proximity: keep a command and its expected output together; keep a config
  key and its explanation in the same table row.
- Similarity: format the same kind of thing the same way. All commands in
  code blocks. All config keys in one table. All file paths in backticks.

Bad (runbook prose):
> then run kubectl get pods -n payments and check that everything is Running
> and afterwards set REPLICAS to 4 in values.yaml and re-deploy

Good:
> Check pod status; all pods must show `Running`:
>
> ```
> kubectl get pods -n payments
> ```
>
> | Setting    | File          | Value |
> |------------|---------------|-------|
> | `REPLICAS` | `values.yaml` | `4`   |

### Write headings that predict content (ISO 5.2.4)

A reader scans headings to decide where to jump. A heading must announce what
its section contains, and nothing else may hide there.

Bad headings: "Miscellaneous", "Some notes", "Part 2".

Good headings: "Rollback procedure", "Why Postgres instead of DynamoDB",
"Known limitations".

### Move supplementary material out of the main flow (ISO 5.2.5)

Keep the main text on the main path. Long logs, stack traces, benchmarks,
and history go into a `<details>` block, an appendix, an attachment, or a
linked doc.

Bad: 120 lines of raw log pasted in the middle of a bug ticket, repro steps
below them.

Good: repro steps and the one decisive log line in the ticket body; the full
log attached or collapsed in a `<details>` block.

---

## Principle 3: Readers can easily understand what they find (ISO 5.3)

Clear wording keeps the reader's attention on the problem instead of on the
text (ISO 5.3.1).

### Choose familiar words, expand every acronym (ISO 5.3.2)

Use the words your readers use. Expand every acronym on first use, even ones
obvious to you; new team members and cross-team reviewers read this too.
Never use internal project jargon without a gloss or a link.

Bad (ticket):
> The CFE rejects the payload before the DLQ hop, probably a P1.

Good:
> The customer-facing endpoint (CFE) rejects the payload before it reaches
> the dead-letter queue (DLQ). Suggested priority: P1 (production down).

### Write clear sentences (ISO 5.3.3)

One idea per sentence. Subject, verb, object. Prefer active voice; name the
actor. Passive voice hides who did what, often exactly what the reader needs.

Bad:
> It was decided that the flag should be removed once verification of the
> rollout, which had been performed in staging, was completed.

Good:
> The team verified the rollout in staging. We then removed the flag.

### Write concise sentences (ISO 5.3.4)

Cut filler phrases: "in order to", "makes use of", "is able to", "it should
be noted that". Every extra word costs reading time multiplied by the number
of readers.

Bad:
> In order to be able to perform the necessary validation of the incoming
> request data, the service makes use of a JSON schema.

Good:
> The service validates incoming requests against a JSON schema.

### Write clear, concise paragraphs (ISO 5.3.5)

One topic per paragraph. Put the point in the first sentence; details follow.
A reader who skims first sentences must still get the argument.

Bad (README): one 15-line paragraph mixing installation, configuration, and
a warning about macOS.

Good: three short paragraphs, each opening with its point: "Install via
Homebrew.", "Configuration lives in one TOML file.", "On macOS, grant Full
Disk Access first."

### Use images, diagrams, and tables where they beat prose (ISO 5.3.6)

Replace relational prose with Mermaid diagrams, screenshots (UI bugs), or
tables (option matrices). Keep a one-sentence takeaway next to every diagram.

Bad: three paragraphs describing which service calls which.

Good:
> The gateway never talks to the ledger directly:
>
> ```mermaid
> sequenceDiagram
>   Client->>Gateway: POST /pay
>   Gateway->>Payments: authorize
>   Payments->>Ledger: book
> ```

### Project a respectful tone (ISO 5.3.7)

This matters most in review comments. Rules:

- Critique the code, not the author. Write "this function", not "you".
- Ask questions where you might lack context, instead of making accusations.
- Be specific: name the file, the line, and a concrete alternative.
- No sarcasm. Sarcasm loses its tone markers in text and reads as contempt.
- Mark severity honestly: prefix non-blocking remarks with "nit:".

Bad (review comments):
> Did you even test this?
>
> Why would anyone name a variable like that?

Good:
> This path throws when `items` is empty (OrderService.kt:87). Can we add a
> test for the empty-cart case?
>
> nit: `data2` is hard to search for. Suggestion: `retryQueue`.

### Keep the text cohesive: one term per concept (ISO 5.3.8)

Use the same word for the same thing throughout. Synonyms that improve essays
create bugs in tickets: the reader cannot tell whether "job", "task", and
"worker run" are one concept or three.

Bad (ticket):
> The job fails. Restarting the task helps. The worker run should be
> idempotent.

Good:
> The export job fails. Restarting the job helps. Jobs should be idempotent.
> (One term, defined once, matching the term in the code.)

---

## Principle 4: Readers can easily use the information (ISO 5.4)

The first three principles make success likely; only evaluation confirms it
(ISO 5.4.1). Treat every text like code: test it, gather feedback, iterate.

### Reread as the reader before submitting (ISO 5.4.2)

Before you press submit, reread the text in the reader's role. Can a
reviewer who has not seen the code decide where to look first? Can the
assignee start work without asking anything? Can a tired stranger execute
the runbook step verbatim? Fix what fails this test, then submit.

### Treat reader questions as test failures (ISO 5.4.3)

Reviewer questions and ticket ping-pong are evaluation data, not noise. When
a reviewer asks "what does this PR actually change?", the description failed
its test. Fix the artifact, not just the thread.

Bad: answer only in the thread; the description keeps misleading later readers.

Good: update the description, then reply: "Good point, added to the
description."

### Keep improving templates and docs from real use (ISO 5.4.4)

Watch how readers actually use your texts. If every incident review shows
on-call skipped the runbook's intro, delete the intro. If the ticket
template's "Impact" field stays empty for a quarter, rework it into a
question people can answer, or drop it.

---

## Checklist

Modeled on the sample-checklist idea of the standard's Annex B. Answer each
question with yes before submitting; every no marks a rewrite.

### Jira ticket

1. Does the first paragraph give a 1-3 sentence TL;DR: problem, impact, ask?
2. Does the title state the specific problem, not just the component?
3. Can the assignee reproduce the bug from the steps alone, without asking?
4. Is the impact stated: who is affected, how badly, since when?
5. Are acceptance criteria listed, testable, and kept in one section?
6. Are logs and screenshots attached or collapsed, not pasted mid-text?
7. Is every acronym expanded on first use, every internal term glossed?

### PR description

1. Does it start with a 1-3 sentence TL;DR of what changed and why?
2. Does it explain why, instead of restating the diff?
3. Are behavior changes, risks, and known limitations stated, none hidden?
4. Are breaking changes and migration steps flagged before the details?
5. Does it tell the reviewer how to test or verify the change?
6. Is background material collapsed or linked instead of inlined?
7. Does it use the same terms as the code it describes?

### Review comment

1. Does the first sentence state the point before any reasoning?
2. Does it address the code, never the author?
3. Is it a question or suggestion wherever you might lack context?
4. Is it specific: file, line, and a concrete alternative?
5. Is severity explicit: blocking, or prefixed with "nit:"?
6. Would you say it face to face, in exactly these words?
