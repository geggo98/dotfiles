---
name: testing
description: "Rules for what makes an automated code test trustworthy: seen red for the right reason, checked with mutations, covering hidden branches, fed with realistic, anonymised and corrupt data, extended by property-based testing and fuzzing, and deterministic. Use when you write, change or review tests. Triggers: write tests, review tests, mutation testing, coverage, branch coverage, MC/DC, test data, anonymise, corrupt data, property-based testing, fuzzing, flaky test."
allowed-tools: Bash(zsh *)
metadata:
  inspired-by:
    - "https://github.com/obra/superpowers (MIT)"
    - "https://github.com/mattpocock/skills (MIT)"
    - "https://github.com/trailofbits/skills (CC BY-SA 4.0, ideas only, no text copied)"
---

# Testing

A test is worth something only if it fails when the code is wrong.
Each section below closes one way in which a test passes although the code is wrong. For the work cycle itself (baseline, minimal change, verify), load the `red-green-refactor` skill.

## Gate: Seen Red, for the Right Reason

1. A new test counts only after it failed against the unchanged code.
2. It must fail for the reason it tests: a wrong value or a missing behaviour.
   A failure from a syntax error, a missing import or a broken fixture does not count. Fix that first and watch the test fail again.
3. Check how many tests ran. "0 tests, BUILD SUCCESSFUL" is not green. A filter or a test selector that matches nothing reports the same as a clean run.
4. Every bug you find becomes a regression test first. See it red, then fix the code, then see it green.

## Never Bend the Test to the Code

- Do not weaken an assertion, skip or disable a test, or rewrite an expected value only to make the test pass.
  The one exception: the requirement has changed, you can show where, and you say so in the change.
- Take expected values from an independent source: the specification, a hand calculation, a reference implementation.
  A value copied from the output of the code only confirms the code.
- Test the public contract, not the internals, so the test survives a refactoring.
- Use real dependencies at interfaces. Run the same database engine and version as production, for example in a container, not an in-memory substitute with a different SQL dialect.
  Mock only at system boundaries (network services, clock, hardware), and never assert on the behaviour of the mock itself.
- Add no test-only hooks or flags to production code.

## Mutations

Check every test with mutations where you can:
put a small fault into the code under test and run the tests again. Typical mutations: flip a comparison, change a constant by one, remove a call, return early, swap `&&` and `||`.

The tests must fail, and the failure message must point to the faulty place. A message such as "expected true but was false" with no context fails the second check.

A mutation tool automates this (see `references/tools.md`). Triage each surviving mutant:

| Finding | Action |
|---|---|
| The mutant behaves exactly like the original (equivalent mutant) | Mark it as equivalent. It cannot be killed, so 100 % is not a goal. |
| The line runs, but no assertion checks its effect | Make the assertion stricter. |
| No test reaches the line | Add a test case. |

Revert every manual mutation. Make it in a scratch worktree or with `git stash`, and prove the revert before you finish. This command must show no change in the production code:

```zsh
git diff
```

## Coverage

Cover all relevant branches, including the hidden ones:

- short-circuit operands: `a && b`, `a || b`, `a ?? b`
- the conditional operator `?:` and safe calls `?.`
- default parameters and implicit exceptions
- loops that run 0, 1 and many times
- `switch` or `when` without an `else` branch

For `a && b`, this means at least three cases: `a` false (`b` is never evaluated), `a` true and `b` false, both true. The criterion that requires each condition to change the outcome on its own is MC/DC (modified condition/decision coverage).

Coverage tools see these branches differently. Some count short-circuit operands as branches, and some measure only jumps between lines. For example, Python's coverage.py with `--branch` does not see a short circuit inside one line.
With such a tool, split a compound condition over several lines or list the cases explicitly in the tests. Which tool sees what, and which compilers measure MC/DC: `references/tools.md`.

Coverage is necessary, not sufficient: a covered line without an assertion is untested. Mutations close that gap.

## Test Data

**Realistic data.** Prefer data derived from the requirements or captured from a production system. Anonymise captured data before it goes anywhere near the repository:

- Pseudonymised data is still personal data. Replacing a name with a stable token is not anonymisation.
- Keep replacements consistent, so that foreign keys and joins still match.
- Rare combinations of values can identify a person. Generalise or remove them.
- Captured data falls under the global agent rule `third-party-data.md`. It never enters a commit without the user's explicit approval.

Document how each capture was made: command, source, date, system version and the anonymisation script. A newer version of the system will need a new capture, and someone must repeat the process. Use the template in `references/test-data-provenance.md`. In examples, use placeholders such as `example-service` or `customer-0001`, never real system, project or person names.

**Corrupt data.** Test every interface with data the current system considers illegal, especially caches and databases. Migrations and manual edits create such data. Examples:

- old serialisation formats in a cache during a rolling deploy
- NULL values from before a constraint existed
- orphaned references and duplicates
- wrong character encoding and truncated values

Define the expected behaviour first: fail loudly, or skip the record. Either way, the message names the record, and one broken record does not stop the whole batch.

**Boundaries and equivalence classes.** Test 0, 1, maximum, maximum + 1 and empty. For dates, test daylight saving changes, 29 February and the end of a month. For text, test Unicode normalisation (NFC and NFD), emoji and umlauts.

## Property-Based Testing and Fuzzing

Property-based tests check a rule over many generated inputs. Useful kinds of property:

- round trip: `decode(encode(x)) == x`
- idempotence: applying an operation twice gives the same result as once
- invariant: a sorted list stays sorted, a balance never goes negative
- oracle: the result matches a simpler reference implementation
- metamorphic: a known change to the input causes a known change to the output

Write generators that produce valid inputs directly. Filters that discard most generated inputs slow the search and hide gaps. Use coverage-guided fuzzing for parsers and binary formats, and turn off checksums and magic-byte checks only in a fuzzing build. Seed the fuzzer with a dictionary of constants taken from the code.

**Guidance finds branches, not volume.** Coverage guidance steers the generator towards new branches. A power user with 50,000 records, a very deep data structure or a worst-case combination usually takes the same branch as a small case, only with a large n. The guidance gains nothing there and does not look for it. For these cases, give the generators size and depth parameters, and add the worst-case and rare high-impact examples as explicit test cases.

Log the seed of every run. Shrink every failure to a minimal example and keep it as a fixed regression test.

## Deterministic Tests

A test gives the same result on every run and on every machine:

- Inject the clock and the time zone. Never read the system time in the code under test.
- Set the locale. A German locale writes a decimal comma, and number parsing changes.
- Fix the random seed, and print it when the test fails.
- Make each test independent of execution order and of shared state.
- Wait for a condition with a timeout, never for a fixed `sleep`.

A flaky test is a defect, not noise. Find the cause; do not add a retry. Where concurrency matters (caches, locks, counters), test parallel access on purpose, with a barrier or a latch that forces the overlap.
