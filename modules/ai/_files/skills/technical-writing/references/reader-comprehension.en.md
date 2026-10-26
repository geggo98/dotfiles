# Reader comprehension: text that can be followed on the first read

The other references in this skill reduce what a reader has to look up: one term per
concept, short sentences, the message first. This one covers what remains when all of
that is satisfied and a text is still hard to follow. The reader has to guess a
referent, rebuild a missing step, or decode a compressed phrase.

Fluent machine text fails this way more often than human text does. A 2026 study that
compared model output with human text and with paraphrases of the same content found
that models favor constructions known to slow readers down, and a follow-up experiment
traced part of the cause to length pressure in training. See "Sources" at the end.

Apply this file to any text, including chat answers and commit messages. For German,
load `reader-comprehension.de.md`.

## 1. Lead with the claim

State the finding, the explanation, or the recommendation first. Do not open with a
position the reader never held and then correct it.

    Bad:  This isn't a caching problem. It's a key-design problem.
    Good: The cache misses because the key includes the request timestamp.

    Bad:  Less configuration. More convention.
    Good: The tool needs no config file when the project follows the default layout.

Keep a negation when it answers a question the reader asked, corrects a mistake the
reader made, or states a real limit.

    Good: Does deleting the symlink remove the package? No. The package stays in the
          store until the next garbage collection.

Do not invent an objection to defeat. If nobody proposed the alternative, leave it out.

## 2. Keep one subject in view

Let each sentence either continue what the reader already holds or announce a change of
topic. Name the same thing the same way every time (STE 1.11 covers terms). A summary
phrase such as "the pattern", "that boundary", or "this approach" must point at
something the reader can identify. If two things qualify, name the one you mean. The
rules for a bare "this" are STE GR-3 and GR-4.

## 3. Say how one statement follows from the last

A conclusion needs its reason when the reader cannot supply it. Write the cause, the
condition, or the intermediate step.

    Bad:  The migration is risky. Run it in a maintenance window.
    Good: The migration locks the `orders` table for the duration of the backfill, so
          writes fail until it finishes. Run it in a maintenance window.

A connector helps when it names a real relationship (STE 4.4). Do not add one as
decoration.

## 4. Use real subjects and real verbs

Let the thing that acts be the subject, and use the verb for what it does. Models
often give an inanimate subject an animate verb, and the sentence then hides what
actually happens.

    Bad:  `is_file()` swallows the error and returns False.
    Good: `is_file()` returns False when the call raises `PermissionError`.

    Bad:  The scheduler eats the retry budget.
    Good: Each retry reduces the retry budget by one, and the scheduler stops at zero.

    Bad:  The loader rides along with the build step.
    Good: The build step also runs the loader.

An ad-hoc verb made from a noun belongs in the same group. "Footnote it" and "calendar
the release" make the reader decode a new word. Use the verb a colleague would expect:
"add a footnote", "put the release in the calendar".

Established technical verbs are fine: "to log", "to cache", "to parse", "to deploy".

## 5. Use an image only when the mapping is obvious

Know the literal meaning before you write the metaphor. Keep an analogy when the reader
can map each part of it without help and it explains something the literal text
explains worse. Drop it when it replaces the claim, when it adds assumptions the facts
do not support, or when the reader must translate it back.

    Bad:  The queue is the heartbeat of the system.
    Good: Every service reads its work from the queue. If the queue stops, no service
          does any work.

Idioms the reader already knows need no explanation or removal.

## 6. Let the thought set the sentence boundary

Keep a reason, a condition, or a consequence attached to its claim when separating it
would hide the relationship. Split a sentence that carries two thoughts. Join
fragments that depend on each other.

    Bad:  Three failures. Same cause. Timeout too low.
    Good: The job failed three times for the same reason: the timeout was too low.

    Bad:  The retry loop waits, and then, if the queue is still full, which happens under
          load, after the third attempt it gives up and reports an error to the caller.
    Good: The retry loop waits and tries again. After the third attempt it gives up and
          returns an error to the caller. The queue is usually still full at that point,
          because the system is under load.

The sentence-length limits from STE still apply (about 20 words for an instruction,
about 25 elsewhere). They set a ceiling. They do not ask for a staccato of short
sentences. Avoid a text where every fact is its own one-line reveal, and avoid a text
where every sentence has the same length. One long sentence for one long thought is
fine.

Where the document mode allows it, take a position. An explanation weighs trade-offs and
says which one wins. A reference stays dry (see plain-language, "Pick the document
type").

## 7. Compression is not concision

"Omit needless words" removes words that do no work. A function word that marks
structure does work. The study above measured the opposite habit in models: they drop
the optional word, stack nouns, and pack meaning into fewer tokens, and readers pay for
it.

| Pattern | Example | Fix |
|---|---|---|
| Dropped optional `that` or `which` | "The config the loader reads is stale." | "The config that the loader reads is stale." |
| Noun stack of three or more | "session token cache invalidation logic" | "the logic that invalidates cached session tokens" (STE 2.1) |
| Ad-hoc verb from a noun | "calendar the release" | "put the release in the calendar" |
| Inanimate subject, animate verb | "the parser chokes on tabs" | "the parser fails on a tab character" |
| Long dependency between related words | "The function, which the loader calls after it has resolved all imports declared in the manifest, returns a list." | "After the loader has resolved all imports from the manifest, it calls the function. The function returns a list." |
| Rare word pair where a common one exists | "idempotent no-op convergence" | "running it again changes nothing" |

Keep each article, each `that`, and each verb. Spell out arrows, symbols, and
abbreviations that the reader has not met (see STE 4.2 and GR-6). Check for the
opposite failure as well: a sentence that obeys every rule here and still sounds
mechanical needs a rewrite, not another rule.

A tool that counts words rewards the compressed version. The reader does not.

## 8. Do not invent facts to sound concrete

Make a vague sentence specific only with facts you have. Do not add a motive, a
mechanism, a number, or a cause that nobody gave you. If the missing fact matters,
ask for it or say that it is unknown. Do not turn a guess into a statement.

    Bad:  The outage was caused by a misconfigured load balancer.
          (the only evidence is a spike in 502 responses)
    Good: The outage started with a spike in 502 responses. The cause is not yet
          known. The load balancer is one candidate.

Keep the writer's voice. Warmth, humor, and useful complexity are not defects.

## 9. Reread once as the reader

Before you send the text, scan it for these places:

1. The reader must guess what a "this", "that", or "the pattern" refers to.
2. A conclusion has no visible reason.
3. A metaphor or an invented label stands where a plain statement would do.
4. A sentence opens with a denial of something nobody said.
5. A dramatic pause (a fragment, a one-line paragraph) takes the place of an
   explanation.
6. A function word, an article, or a verb is missing.

Repair what you find. Add nothing the facts do not support, and do not append a report
about the review.

## Sources

This file distills the following. The wording and the examples are original.

- Why is AI-generated language so hard to understand? arXiv 2610.29162, 2026.
  <https://arxiv.org/html/2610.29162>
  Measured features: rare n-grams, long dependencies, stacked nouns, ad-hoc verbs from
  nouns, inanimate subjects with animate verbs, and reduced relative clauses. The authors
  call their length-penalty experiment a proof of concept on a small model.
- writing-clarity.md, a public gist, as of the commit
  `3bc8462be49b7e34e49a547e56a9e756c5404a59`.
  <https://gist.github.com/lxe/4cd2ca0fd3b714b25f138227c8c650d3>
- `unslop` and `technical-writing` from the pstack plugin, MIT license.
  <https://github.com/cursor/plugins/tree/main/pstack/skills>
  See `anti-tropes-instruction.md` for the catalog entries taken from `unslop`, and
  `plain-language.en.md` and `simplified-technical-english.en.md` for the parts taken
  from `technical-writing`.
