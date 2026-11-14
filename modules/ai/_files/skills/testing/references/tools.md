# Testing Tools

Reference for the [`testing`](../SKILL.md) skill.
Use it to pick a tool for mutation testing, coverage,
property-based testing or fuzzing,
and to know what that tool can and cannot see.

Tools change between releases.
Before you rely on a flag, a version or a counting rule,
check it against the tool's current documentation.

## Mutation Testing

A mutation tool makes small changes to the code under test
and runs the tests against each changed version (a mutant).
A mutant that no test catches shows a gap in the tests.

| Language | Tool |
|---|---|
| JVM (Java, Kotlin) | PIT |
| JavaScript, TypeScript, C#, Scala | Stryker |
| Python | mutmut, cosmic-ray |
| Rust | cargo-mutants |

## Branch Coverage and Short-Circuit Conditions

In `a && b`, the operand `b` runs only when `a` is true.
The tools below count this hidden branch in different ways.
A coverage report of 100 % can therefore mean different things.

| Tool | Language | What it counts for `a && b` |
|---|---|---|
| JaCoCo | JVM | Each `&&` and `\|\|` operand compiles to its own conditional jump in bytecode. JaCoCo counts each jump as two branches, so `if (a && b)` has 4 branches. |
| Istanbul (nyc) | JavaScript, TypeScript | Counts logical expressions (`&&`, `\|\|`, `??`) as branches of type `binary-expr`, with one location for each operand. A test set where `b` is never skipped shows as partial coverage. |
| coverage.py with `--branch` | Python | Follows jumps between lines only. It does not see a short-circuit inside one line. For `if a and b:` on one line, one true run and one false run give 100 %, even if `b` never ran. |

## MC/DC

MC/DC (modified condition/decision coverage) requires that each condition
in a decision is shown to change the outcome on its own,
while the other conditions stay fixed.
Branch coverage does not give this guarantee.

| Tool | Language | MC/DC |
|---|---|---|
| Clang `-fcoverage-mcdc` | C, C++ | Yes, from LLVM 18 |
| GCC `-fcondition-coverage` | C, C++ | Yes, from GCC 14 |
| rustc `-Zcoverage-options=mcdc` | Rust | Yes, nightly only |
| JaCoCo | JVM | No |
| coverage.py | Python | No |
| Istanbul (nyc) | JavaScript, TypeScript | No |

For Python, there are two ways to cover each condition:

- Break a compound condition over several lines,
  so that `coverage.py --branch` sees each part as its own jump.
- List the cases by hand: one test for each condition
  that changes the outcome on its own.

## Property-Based Testing

A property-based test states a rule that must hold for all inputs.
The tool generates many inputs and shrinks a failing input
to a small counterexample.

| Language | Tool | Notes |
|---|---|---|
| Python | Hypothesis | `target()` steers generation toward inputs that score high on a metric that you give. HypoFuzz, a separate add-on (`pip install hypofuzz`, hypofuzz.com), runs Hypothesis tests as a coverage-guided fuzzer. |
| JVM | jqwik | Generates edge cases in addition to random values. |
| JavaScript, TypeScript | fast-check | |
| Rust | proptest | |

## Coverage-Guided Fuzzing

A coverage-guided fuzzer instruments the code
and keeps the inputs that reach new branches.
It finds new paths through the code.
It does not find inputs that take a known path with a very large size or depth.
For those, write your own generators or explicit worst-case examples
(see [Property-Based Testing and Fuzzing](../SKILL.md#property-based-testing-and-fuzzing) in the `testing` skill).

| Language | Tool |
|---|---|
| C, C++ | libFuzzer, AFL++ |
| JVM | Jazzer |
| Python | Atheris |
| Go | `go test -fuzz` |
