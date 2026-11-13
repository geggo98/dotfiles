---
name: technical-writing
description: "Use when writing documentation, commit messages, error text, explanations, reports, or summaries. Applies especially to Jira tickets, pull request descriptions, and review comments: always start these with a TL;DR summary. Combines Strunk, ASD-STE100 (Simplified Technical English), and ISO 24495-1 (plain language), for English and German text. Text for people is drafted by Opus 5.5 or a Sol-class model, never by Fable 5.1 or 5.2 (section Which Model Writes), and a fresh agent checks that it is self-contained (section Fresh-Eyes Review). Triggers: writing human-readable content, verbose text, unclear explanations, Jira tickets, pull requests, review comments, AI-sounding text, unslop."
allowed-tools: Read(references/*) Bash(zsh *) Read
---

# Writing Clearly and Concisely

Vigorous writing is concise.
A sentence should contain no unnecessary words,
a paragraph no unnecessary sentences,
for the same reason that a drawing should have no unnecessary lines and a machine no unnecessary parts.

# Jira Tickets, Pull Requests, Review Comments

This skill applies especially to Jira tickets,
pull request descriptions,
and review comments.

Always start these with a TL;DR:
one to three sentences,
outcome or request first.
Label it `TL;DR:` where the medium allows;
otherwise the first paragraph is the summary.
This applies ISO 24495-1's first findability rule:
place the most important message at the beginning.

Jira ticket:
TL;DR, then context, then steps or acceptance criteria.

Pull request description:
TL;DR (what changed and why), then details, then how to test.

Review comment:
main point first, then reasoning, then a concrete suggestion.
Critique the code, not the author.

# Which Model Writes

Text that people will read is drafted by Opus 5.5 (`claude-opus-5-5`)
or a model of the Sol class (OpenAI, for example `gpt-6.1-sol`).
Fable 5.1 and Fable 5.2 (`claude-fable-5-1`, `claude-fable-5-2`) do not write
such text, even when they are the model of the running session.
This covers tickets, comments, pull request descriptions, review comments,
ADRs, design documents, chat messages, and narration.
Mechanical text does not: commit trailers, labels, IDs.

If you already run on Opus 5.5 or a Sol-class model, write the text yourself.
On any other model, including Fable 5.1 and 5.2, delegate.

Delegate the writing. Do not switch models in the running session:
a switch discards the prompt cache and is expensive.
Start a separate run with a short brief instead:

- Claude Code: the `Agent` tool with `model: "opus"` (Opus 5.5, never `"fable"`).
  The brief tells it to load `Skill(technical-writing)`,
  write the draft to a file, and return the path.
- Codex: the default is already `gpt-6.1-sol`, so write it yourself.
  On another model, use a sub-agent or `codex exec -m gpt-6.1-sol` with the same brief.

The brief holds everything the writer needs,
because it does not see this session:

- purpose and medium (Jira wiki markup, Bitbucket Markdown, Slack)
- the reader
- the language, taken from the existing discussion
- the facts, as bullet points
- required parts, such as the attribution footer or a quoted prompt
- a length limit and the output file

Check the draft for facts and required parts only, not for style.
Post it through the usual `--file` or stdin route.
If the facts are wrong, send a corrected brief back.
Do not rewrite the draft yourself.

If no Opus 5.5 or Sol model is reachable (for example Gemini or Antigravity),
or the delegation fails: do not post.
Ask the user, and offer a headless run:
`claude -p --model opus …` or `codex exec -m gpt-6.1-sol …`, brief on stdin.
Start no other CLI without the user's consent.

# Fresh-Eyes Review

A document that leaves the session must make sense without the session.
After the draft exists, a fresh agent reads it cold and checks one property:
the document is **conceptually closed**.
Every term is either common knowledge for the intended reader
or defined in the document.
Nothing points at something that exists only in the session.

This applies to text that outlives the conversation or reaches people without it:
tickets, pull request descriptions, ADRs, design documents, READMEs, runbooks, reports.
It does not apply to replies inside the running conversation,
where the reader holds the context.

**What the reviewer flags:**

- a term, abbreviation, option or component name that is neither common
  knowledge for the reader nor defined in the text
- a name coined during the session: a nickname for an approach,
  a variable, a branch, a "plan B", "the first option"
- a back-reference with no target in the document:
  "as discussed", "the above", "the earlier finding", "this change" when
  the text never says which change
- an identifier with no locator: a ticket key, PR number, or file path
  that the reader cannot open from the text alone

**What is fine:** a reference to a glossary or another document,
provided it is **stored together with this one**
(same repository, same ticket system, same wiki)
and the text says where to find it.
A link to a glossary on one person's laptop is not a definition.

**How to run it:**

- The reviewer is a fresh agent **without access to the session**:
  in Claude Code the `Agent` tool with a general-purpose type, never a fork;
  in a Workflow script a plain `agent()` call.
- The brief holds only the path of the draft, the intended reader,
  where the co-located documents live (repository path, wiki space, ticket project),
  and the checklist above.
  No summary of the session, no hints, no list of terms the author considers known.
  Anything you add to the brief leaks context the real reader will not have.
- Ask for structured findings: the quoted passage, the category,
  and the fix ("define in place" or "link to <co-located document>").
  The reviewer does not rewrite the text.
- Apply the fixes yourself, define the term in place or add the link, and run the review again
  with a new agent.
  Stop when a round returns no findings, after at most three rounds.
  If the third round still finds problems, tell the user instead of posting.

```js
const FINDINGS = { type: "object", properties: { findings: { type: "array", items: {
  type: "object", required: ["quote", "category", "fix"],
  properties: { quote: { type: "string" },
    category: { enum: ["undefined-term", "session-coinage", "dangling-reference", "locator-missing"] },
    fix: { type: "string" } } } } }, required: ["findings"] }
// The prompt carries the path, the reader and the co-located locations. Nothing else.
const r = await agent(
  `Read ${path}. Intended reader: ${reader}. Co-located documents: ${where}. ` +
  `Report every passage that fails the checklist.`,
  { label: "fresh-eyes", schema: FINDINGS })
```

# Core Principles

Make paragraph the unit of composition:
One paragraph per topic.
Does each paragraph develop a single idea?

Use active voice:
"The committee approved" not "The committee gave approval."
Default to active unless actor is unknown or unimportant.

Put statements in positive form:
Say what is,
not what isn't.
"He thought Latin useless" not "He did not think Latin was useful."

Use definite, specific, concrete language:
"It rained every day for a week" not "A period of unfavorable weather."
"He grinned" not "He showed satisfaction."

Keep related words together:
Don't separate subject from verb or verb from object unnecessarily.
"In 1865 he published his work" not "He published, in 1865, his work."

Place emphatic words at sentence end:
"Although improvements occurred, crime increased" not "Crime increased, although improvements occurred."

If a rule makes a sentence worse, rebuild the sentence or leave it alone.
A sentence that obeys every rule and still sounds mechanical has failed.

# Readable on the First Pass

Concise is not the same as compressed.
A reader follows a text on the first read when each sentence names its subject,
each conclusion shows its reason,
and no function word has been cut to save a token.
Lead with the claim, not with a denial of something nobody said.
Give code a real verb: "returns False", not "swallows the error".

See [reader comprehension](references/reader-comprehension.en.md)
for the patterns and the one-minute reread checklist.
For German text, load [Verständlichkeit beim ersten Lesen](references/reader-comprehension.de.md).

# Quantities and Ratios

For quantity statements such as "x of y" or "x von y",
keep both counts and immediately add their ratio in parentheses.
Calculate x / y before rounding.
Choose a decimal fraction, percentage, per mille, or basis points
according to the domain; default to percentages when no convention applies.
Use two significant figures by default, adjusting precision when needed
to preserve a meaningful distinction.
Percent means x / y × 100, per mille × 1,000, and basis points × 10,000.

Mark approximations explicitly:
"about", "approximately", "just under", "just over", "more than", "less than";
in German, "ca.", "rund", "knapp", "gut", "mehr als", "weniger als".
Directional wording must agree with the unrounded value:
"knapp" / "just under" means below the stated value,
"gut" / "just over" means above it.
Exact ratios may be stated exactly without an approximation marker.

Examples (use the number formatting of the surrounding language):

- Decimal fraction: "34 von 456 (ca. 0,075)".
- Percentage: "34 von 456 (ca. 7,5 %)" or "34 von 456 (mehr als 7 %)".
- Per mille: "3 von 2 000 (ca. 1,5 ‰)".
- Basis points: "3 of 20,000 (about 1.5 basis points)".
- Exact: "1 of 4 (25%)".

Do not invent a ratio when a count is unknown;
for a zero denominator, state that the ratio is undefined.
Do not rewrite verbatim quotations or machine-readable data to add ratios.

# Omit Needless Words

Eliminate verbose constructions:

- "the question as to whether" -> "whether"
- "there is no doubt but that" -> "no doubt"
- "used for fuel purposes" -> "used for fuel"
- "he is a man who" -> "he"
- "in a hasty manner" -> "hastily"
- "this is a subject that" -> "this subject"
- "the reason why is that" -> "because"
- "owing to the fact that" -> "since" or "because"
- "in spite of the fact that" -> "though" or "although"
- "call your attention to the fact that" -> "remind you"
- "the fact that" -> (delete or rephrase)
- "as to whether" -> "whether"

Don't bury the main point:
"My arrival caused consternation" not "The fact that I had arrived was enough to cause consternation."

Omit words that do no work.
Keep words that mark structure:
articles, "that" or "dass", and verbs.
Cutting these is the compression pattern that makes machine text hard to read
(see [reader comprehension](references/reader-comprehension.en.md), section 7).

# Needless Words

**case:**
"In many cases, tests fail" -> "Tests often fail"

**character, nature:**
"Acts of hostile character" -> "hostile acts"
"Technical nature" -> "technical"

**factor:**
"Training was a factor" -> "Training contributed" or "They won through training"

**feature:**
Hackneyed word.
Avoid as verb.

**interesting:**
Don't announce content is interesting.
Make it interesting.

**very:**
Use sparingly.
"Very tired" -> "exhausted"

**respective, respectively:**
Usually omissible.

# Technical Writing Usage

**data:**
Plural.
"These data show" not "This data shows"

**fewer vs less:**
"fewer bugs" (countable),
"less memory" (quantity)

**while:**
Means "during the time that."
Don't substitute for "and," "but," or "although."

**etc.:**
Don't use after "such as" or "for example."
Avoid if reader uncertain what's included.

# Edit Ruthlessly

When writing:

1. Draft without constraint
2. Replace vague with specific
3. Eliminate needless words
4. Use active voice
5. One topic per paragraph
6. Emphatic words at end
7. Reread once as the reader, using the checklist in reader comprehension, section 9
8. For text that leaves the session, run the Fresh-Eyes Review

Every word must justify its presence.

# References

See [Simplified Technical English](references/simplified-technical-english.en.md)
for word, sentence, and procedure rules --
ASD-STE100 Issue 9 adapted to IT writing
(terminology, noun clusters, verbs, sentence limits,
runbook steps, warnings).

See [plain language](references/plain-language.en.md)
for structure and audience --
ISO 24495-1's four principles
(relevant, findable, understandable, usable)
adapted to Jira tickets, pull requests, and review comments,
with per-format checklists.

For German text, load the German adaptations instead:
[Technisches Deutsch](references/simplified-technical-english.de.md)
and [Klare Sprache](references/plain-language.de.md).
They adapt the rules to German
(compound nouns, nominal style, Imperativ vs. Infinitiv)
rather than translating them.

See [editorial mechanics](references/editorial-mechanics.en.md)
for the typographic layer the two standards above leave open --
comma rules, hyphens, slashes, em dash spacing,
heading capitalization, list and procedure formatting,
`a` versus `an`,
and the requirement that every example be tested.
Its last section records which rules from other house style guides
this skill deliberately does not follow, and why,
so a settled question stays settled.

For German text, load [Redaktionelle Mechanik](references/editorial-mechanics.de.md).
It is an adaptation, not a translation:
German commas follow grammar rather than style,
the Halbgeviertstrich takes the spaces the em dash refuses,
there is no title case,
and `a`/`an` has no counterpart at all --
its place is taken by the gender of English loan words.

See [anti-tropes-instruction](references/anti-tropes-instruction.md)
for specific writing patterns to avoid --
word choice, sentence structure, tone, and formatting tropes
that signal AI-generated or formulaic prose.

See [signs of AI writing](references/signs_of_AI_writing.md)
for a field guide to detecting AI-generated content --
vocabulary tells, structural patterns, markup artifacts,
and citation problems common in LLM output.

See [reader comprehension](references/reader-comprehension.en.md)
for what remains when a text is concise and still hard to follow --
referents, missing steps, personified code, and compression patterns
that studies of machine text have measured.
The German adaptation is
[Verständlichkeit beim ersten Lesen](references/reader-comprehension.de.md).
