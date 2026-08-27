# Editorial mechanics for English IT writing

The other references in this skill govern what you say and how you structure it.
This one governs the typography underneath: commas, hyphens, slashes, dashes, heading case,
list and procedure formatting, and article choice. None of it is covered by ASD-STE100 or
ISO 24495-1, because neither standard is a house style guide.

Rules here cross-reference the file that owns the adjacent rule, so you can see what is an
extension and what is new ground. A final section records which rules from other house style
guides this skill deliberately does not follow, and why.

## 1. Commas

Only one comma rule exists elsewhere in this skill (STE 5.4, condition before command).
These are the rest.

Use the serial comma before the final item in a list of three or more (the Oxford comma).
Without it, the last two items can read as an apposition to the first.

    Ambiguous: We invited the dancers, John and David.
               (Are John and David the dancers, or three separate parties?)
    Clear:     We invited the dancers, John, and David.

    Bad:  The job drains the node, upgrades the kernel and reboots.
    Good: The job drains the node, upgrades the kernel, and reboots.

Use a comma before a coordinating conjunction (and, but, for, or, nor, so, yet) that joins
two independent clauses. Use no comma when one subject governs both verbs.

    Two clauses: The migration completed, and the replicas caught up within a minute.
    One subject: The migration completed and left the replicas two minutes behind.

Use a comma after an introductory phrase or adverb.

    Bad:  With the sidecar enabled the pod needs 200 MB more memory.
    Good: With the sidecar enabled, the pod needs 200 MB more memory.

    Bad:  Finally the operator reconciles the CRD.
    Good: Finally, the operator reconciles the CRD.

Use a comma after a sequence word that opens a step: first, next, then, after that, last.

    Good: First, stop the writer. Then, truncate the table. Last, restart the writer.

Use a comma after any dependent clause that opens a sentence: when, after, although, as,
because, before, once, since, while. STE 5.4 states this for conditions; it holds for every
dependent clause, not only for `if`.

    Bad:  Restart the collector after you rotate the certificate.
    Good: After you rotate the certificate, restart the collector.

Use a comma between two adjectives that modify the same noun independently. Test by swapping
them: if the swapped order still reads correctly, the comma belongs there.

    Good: a slow, unindexed query        (an unindexed, slow query -- still correct)
    Good: a new database driver          (a database new driver -- wrong, so no comma)

Never join two independent clauses with a comma alone. Write two sentences.
The semicolon is not available as a fix here: STE 8.1 forbids it.

    Bad:  The token is short-lived, refresh it before each call.
    Also bad (semicolon banned by STE 8.1):
          The token is short-lived; refresh it before each call.
    Good: The token is short-lived. Refresh it before each call.

If a sentence needs more than one or two commas to hold together, the punctuation is not the
problem. Rewrite it. The word limits in STE 5.1 and 6.3 usually catch the same sentence.

## 2. Hyphens

STE 8.2 says to hyphenate directly related words and STE 2.2 caps a hyphenated group at three
words. These are the cases that trigger the hyphen.

Hyphenate two or more words that precede and modify a noun as a unit, when the reader could
otherwise attach the first word to the wrong thing.

    Bad:  a read only token, a built in retry
    Good: a read-only token, a built-in retry

Hyphenate when one element is a participle, that is a verb form in -ed or -ing used as a
modifier.

    Good: left-aligned text, well-defined schema, ever-growing backlog

Hyphenate when the modifier is a number or a single letter plus a noun.

    Good: a 5-minute timeout, a 3-node cluster, an S-shaped curve

The same words are often a noun without the hyphen and a modifier with it. Hyphenate only in
the modifier position.

    Noun:     Run it from the Linux command line.
    Modifier: Use a command-line tool.

Hyphenate a compound whose first element is an abbreviated word, but note the words that have
outgrown the hyphen through use.

    Good: e-book, e-commerce
    But:  email

Hyphenated groups count as one word against the sentence limits (STE 8.7).

## 3. Slashes

Nothing else in this skill covers the slash.

Use a forward slash to mean a genuine combination of both things at once. If the first element
is capitalized, capitalize the second.

    Good: client/server, Client/Server, TCP/IP, read/write

Do not use a slash to mean "or". It saves two characters and forces the reader to guess
whether you meant one, the other, or both.

    Bad:  Set the retention on the bucket/prefix.
    Good: Set the retention on the bucket or the prefix.

    Bad:  Ask the author/reviewer to confirm.
    Good: Ask the author or the reviewer to confirm.

The slash is never the fix for a gendered pronoun. GR-7 already answers that: repeat the role
noun or use "they".

    Bad:  Ask the reviewer whether he/she approved the change.
    Good: Ask the reviewer whether they approved the change.

## 4. Em dashes

The mechanical rule, which nothing else in this skill states: in English, an em dash takes no
spaces around it.

    Bad:  The payload — numbers, config, and text — is stored in one blob.
    Good: The payload—numbers, config, and text—is stored in one blob.

Read that together with the two rules that already exist and that constrain how often you
reach for one. `anti-tropes-instruction.md` caps em dashes at two or three per piece and
forbids them as the default mechanism for asides. `signs_of_AI_writing.md` records that LLM
output uses them where humans use a comma, a parenthesis, or a colon.

So: prefer the comma, the parenthesis, or the colon. When an em dash is genuinely the right
mark, set it without spaces.

## 5. Headings: capitalization

Use sentence case at every heading level. Capitalize the first word and proper nouns, and
nothing else. After a colon, capitalize the first word.

    Bad:  ## Rolling Back A Failed Release
    Good: ## Rolling back a failed release

    Good: ## Network: Setup and configuration
    Good: ## Why Postgres instead of DynamoDB

Preserve the case of UI labels, commands, and API identifiers exactly as the product writes
them, including at the start of a heading. If a lowercase identifier at the start of a heading
looks like a typo, rewrite the heading so it is not first.

    Bad:  ## Fdisk partitioning
    Good: ## Partitioning with fdisk

## 6. Lists

Pull three or more parallel items out of running text and set them as a list. This trigger is
what turns a dense sentence into something scannable, and no other rule here states it.

    Bad:  The exporter reads the queue depth, the consumer lag, the retry count, and the
          dead-letter size, and reports all four to Prometheus.
    Good: The exporter reports four values to Prometheus:

          - queue depth
          - consumer lag
          - retry count
          - dead-letter size

Use a bulleted list when the items have no required order, and a numbered list when the reader
must work through them in sequence. This rule existed only in `plain-language.de.md`,
with no counterpart on the English side.

Keep one style within a list. Either every item is a full sentence that ends with a period, or
every item is a fragment and none of them does. Capitalization follows the same rule. Do not
mix the two.

    Bad:  - Stop the writer.
          - truncate the table
          - Restart the writer

    Good: - Stop the writer.
          - Truncate the table.
          - Restart the writer.

    Good: - queue depth
          - consumer lag
          - retry count

Where a list really is a set of term-and-definition pairs, set the term in bold and the
definition in plain text. Treat this as the narrow exception it is:
`anti-tropes-instruction.md` forbids beginning every bullet with a bolded phrase, and
`signs_of_AI_writing.md` lists the bullet-plus-bold-header-plus-colon shape as an AI tell.
The bold marks a defined term. It is not the default shape of a bullet.

Where the items are links with descriptions, put the link first and indent the description
underneath it.

Two counting rules already apply: a colon before a vertical list ends the sentence, and each
item counts as its own sentence against the word limit (STE 8.4). Do not mix instructions and
description in one list (STE 4.3).

## 7. Procedures: numbering and step boundaries

These extend STE section 5, which governs the content of a step but not its shape.

When a procedure has exactly one step, set it as a bullet rather than as a numbered list of
one. A "1." with no "2." makes the reader look for the rest.

    Bad:  Closing the program
          1. To close the program, choose Exit on the File menu.
    Good: Closing the program
          - To close the program, choose Exit on the File menu.

Label sub-steps with lowercase letters, and sub-sub-steps with lowercase Roman numerals.

    1. Prepare the node:
       a. Cordon the node.
       b. Drain the workloads:
          i.  Evict the stateless pods.
          ii. Fail over the stateful sets.
    2. Upgrade the kernel.

Keep a confirming keypress in the same step as the action it confirms. Split across two steps,
it reads as an independent action and invites the reader to pause between them.

    Bad:  1. Click the search box, then type the function name.
          2. Press Enter.
    Good: 1. Click the search box, type the function name, and press Enter.

State the purpose before the action, so a reader whose purpose differs can skip the step
without parsing it. This is the purpose-shaped twin of STE 5.4, which puts the condition first.

    Bad:  Click File > New > Document to start a new document.
    Good: To start a new document, click File > New > Document.

Give each procedure a heading, and phrase sibling procedures the same way. An introductory
sentence may precede the steps, but it must add context rather than restate the heading.

    Good: ## Closing the program
          ## Restarting the program
          ## Uninstalling the program

## 8. Articles: `a` or `an` by sound

STE 4.5 requires the article to be there. It does not say which one to use.

Choose by the sound of the following word, not by its first letter.

    Good: an MGC        (M is pronounced "em", a vowel sound)
    Good: a URL         ("yoo", a consonant sound)
    Good: an hour       (silent h)
    Good: a European, a university, a unit
    Good: a historical record   ("an historical" is archaic in American English)

In IT writing the live case is the acronym that two people pronounce differently. Whether it is
"an SQL query" or "a SQL query" depends on whether the project says "ess-cue-ell" or "sequel".
Decide once, record it in the glossary, and hold it. That is STE 1.11 applied to pronunciation.

## 9. Acronyms you use only once

ISO 5.3.2 requires you to expand every acronym on first use. This adds the case it does not
cover: if the term appears only once in the whole text, do not introduce an abbreviation at
all. An abbreviation that is defined and never reused costs the reader an extra clause and
saves nobody anything.

    Bad:  The scheduler uses Kernel Samepage Merging (KSM) to reduce memory use.
          (KSM never appears again)
    Good: The scheduler uses kernel samepage merging to reduce memory use.

    Good: Kernel Samepage Merging (KSM) reduces memory use. KSM scans anonymous pages
          every 20 minutes, so KSM savings appear gradually.

## 10. Examples must be correct and tested

Every command, configuration snippet, and code block must have been run in the state the text
describes, and must have produced what the text claims.

It is better to have no examples than bad ones. An untested example is not a partial help; it
is a defect that ships, because the reader trusts it more than the prose around it and debugs
your example instead of their problem.

When an example cannot be run as written, say so on the line above it, and say what is missing.

    Bad:  Run `just deploy --all` to roll out every service.
          (never run; the flag is actually --every)
    Good: Run `just deploy --every` to roll out every service.

    Good: The following is illustrative and will not run as written -- substitute your
          own bucket name and region:

This is the writing-side twin of the citation checks in `signs_of_AI_writing.md`: a broken link
and an untested command fail the same way, by looking authoritative and being wrong.

## 11. Third-party names, and naming the synonyms once

Write a third-party product name the way its owner writes it. Capitalization is part of the
name, not a style choice, and neither habit nor autocorrect is the authority. The product's own
documentation is.

    Bad:  VMWare, CentOs, openvz, Postgresql, NPM, MacOS, github
    Good: VMware, CentOS, OpenVZ, PostgreSQL, npm, macOS, GitHub

This extends STE 1.6 and 1.8, which take component names from code, API docs, and the glossary.

STE 1.11 requires one term per concept, and that stays. Add one move on top of it: name the
common alternatives exactly once, at first use, so a reader searching for the other word still
lands on your text. Then use the chosen term everywhere after.

    Good: A USB flash drive (also called a USB stick) is the recommended install medium.
          Write the image to the USB flash drive, then boot from it.

## 12. Deliberately not adopted

These rules appear in other house style guides, notably the Proxmox VE Technical Writing Style
Guide from which much of this file is drawn. They are recorded here as decided, not as
oversights, so the same comparison does not surface them again as gaps.

**The semicolon to repair a comma splice.** STE 8.1 forbids the semicolon outright, on the
grounds that it invites long sentences and is easy to misuse. Write two sentences instead. See
section 1.

**Contractions.** STE 4.2 forbids `it's`, `you're`, and `don't` in body text, with one
exception for Conventional Commits subject lines. Other guides permit common contractions and
forbid only noun-verb ones. This skill keeps the stricter rule, because it also serves
translation and non-native readers.

**`data` as a singular noun.** `SKILL.md` treats `data` as plural: "These data show", not "This
data shows". Both are defensible in current usage; the point is that one of them is chosen and
held.

**Title case for top-level headings.** Other guides set H1 and H2 in title case and lower
levels in sentence case. `signs_of_AI_writing.md` lists title case in headings as a marker of
LLM output, so this skill uses sentence case at every level. See section 5.

**Bold-first bullets as a general pattern.** Permitted only for genuine term-and-definition
lists, per section 6. `anti-tropes-instruction.md` and `signs_of_AI_writing.md` both flag the
habit of opening every bullet with a bolded phrase.

**Skipping the expansion of well-known acronyms.** Other guides let USB, HTML, URL, and FAQ
stand unexpanded. `plain-language.en.md` requires expanding every acronym on first use, "even
ones obvious to you", and that rule wins here. Section 9 adds only the case where the term
appears once and needs no abbreviation at all.

**A table of transition words by function.** Genuinely absent from this skill, and deliberately
left absent. Half the entries such a table would carry -- Additionally, Moreover, Furthermore,
Notably, Importantly -- appear on the banned lists in `anti-tropes-instruction.md` and
`signs_of_AI_writing.md`. STE 4.4 covers what is needed: use a connector between related
sentences, and use a plain one.
