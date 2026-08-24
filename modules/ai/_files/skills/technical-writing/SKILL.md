---
name: technical-writing
description: "Use when writing documentation, commit messages, error text, explanations, reports, or summaries. Applies especially to Jira tickets, pull request descriptions, and review comments: always start these with a TL;DR summary. Combines Strunk, ASD-STE100 (Simplified Technical English), and ISO 24495-1 (plain language), for English and German text. Triggers: writing human-readable content, verbose text, unclear explanations, Jira tickets, pull requests, review comments."
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

See [anti-tropes-instruction](references/anti-tropes-instruction.md)
for specific writing patterns to avoid --
word choice, sentence structure, tone, and formatting tropes
that signal AI-generated or formulaic prose.

See [signs of AI writing](references/signs_of_AI_writing.md)
for a field guide to detecting AI-generated content --
vocabulary tells, structural patterns, markup artifacts,
and citation problems common in LLM output.
