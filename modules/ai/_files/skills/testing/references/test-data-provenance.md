# Test Data Provenance

Test data captured from a live system go stale when that system changes.
To refresh them for a newer version, someone must repeat the original capture.
They can do that only when the capture is written down.
Fill in the template below for every data set you take from a live system,
and store it next to the data.

## Clearance Comes First

Live data almost always contain personal data of third parties:
names, email addresses, account ids, handles.
They also contain names of internal infrastructure:
hosts, repositories, products, project keys, cloud project ids, ticket numbers.

Neither kind may enter a public repository without explicit clearance from the person who owns the repository.
A clearance applies to one change only and does not carry over.
This also applies to the provenance record itself:
the capture command often names a host, a database, or a project.
Write those parts as placeholders such as `<source-system>` or `<db-host>`,
and keep the real values outside the repository.

The full rule is the global agent rule `third-party-data.md`,
which is installed alongside this skill.
In the nix-darwin repository, its source is `modules/ai/_files/rules/third-party-data.md`.

## Template

Copy this block into a file next to the data set,
for example `<data-set>.provenance.md`.

```markdown
# Provenance: <data-set>

- Source system and version: <source-system> <version>
- Capture date: <YYYY-MM-DD>
- Captured by: <role, not a name>
- Command or query (exact, with placeholders for hosts and credentials):

      <command or query>

- Selection criteria: <which records, why these, how many of how many>
- Anonymisation script: <path in the repository> at commit <commit>
- Anonymisation steps:
  1. <field or column>: <replaced with what, consistent or random>
  2. ...
- Deliberately kept:
  - shapes: <structure, nesting depth, optional fields that are absent>
  - rare combinations: <which ones, and why they matter for the tests>
  - sizes: <record counts, longest lists, largest values>
- Replaced: <every field that changed, and the replacement rule>
- Re-capture for a new version:
  1. <step>
  2. <step>
  3. Run the anonymisation check below.
- Anonymisation check: <how it was done, date, result>
```

## How to Fill In the Fields

**Command or query.**
Copy the command that produced the data, not a description of it.
Replace hosts, credentials, and project names with placeholders.
If the capture needed several commands, list all of them in order.

**Selection criteria.**
State why you chose these records.
"The 50 accounts with the most orders" can be repeated.
"Some accounts that looked interesting" cannot.
Give the count against the total, for example "50 of 120,000 accounts (about 0.042 %)".

**Deliberately kept.**
Realistic test data are valuable because of their shape, not their values.
Record what must survive anonymisation:
deep nesting, missing optional fields, very long lists,
and rare combinations that triggered a past defect.
A later capture must select records that keep these properties.

**Replaced.**
List every field you changed.
A field that is missing from this list counts as unchanged,
and a reviewer will check it as live data.

**Re-capture for a new version.**
Write the steps so that a person who did not do the first capture can follow them.
Include the version check:
which version the data came from, and how to confirm the version of the new source.

## Check That the Anonymisation Holds

**Pseudonymisation is not anonymisation.**
Pseudonymisation replaces an identifier with a substitute
but keeps a way back, for example a mapping table or a keyed hash.
Under the GDPR (Recital 26), pseudonymised data are still personal data.
Data are anonymous only when nobody can link them to a person again
with reasonable effort.
Do not commit the mapping table or the hash key.

**Replace consistently.**
Use the same substitute for the same original value in every table and file.
Then foreign keys, joins, and duplicate checks still work,
and the tests still see the same relationships as the live system.
Random replacement per occurrence breaks these relationships silently.

**Rare combinations identify people.**
Postcode, birth date, and job title can identify a person
even when the name is removed.
For each rare combination that you keep on purpose,
check that it does not point to one real person.
If it does, change the values but keep the combination's structure.

**Check the result, not the script.**
Search the anonymised data for the shapes of identifiers,
not only for known names:
email addresses, id-like strings, ticket patterns such as `ABC-1234`,
host names, and repository slugs.
Before you accept "no hits", count how many lines the search read.
A search that read nothing also reports no hits.
