"""Build one +devdocs SQLite index from a valkey-doc (or redis-doc-shaped)
source tree: one page per command under `commands/*.md`, plus topic guide
pages under `topics/*.md`.

Runs at NIX BUILD TIME inside modules/devdocs.nix's `mkRedisDoc` derivation,
against the directory `pkgs.fetchzip` produces from a GitHub archive tarball.

Structure MEASURED against valkey-io/valkey-doc (2026-09-18), which is NOT
the shape the original DevDocs `redis` family or the (now archived)
`redis/redis-doc` repo have -- valkey-doc ships no top-level `commands.json`
metadata file at all, just the command pages themselves:

  commands/<slug>.md   one file per command/subcommand, plain Markdown body,
                       NO front matter, NO title line (the site's own theme
                       adds the heading). A SUBCOMMAND's slug hyphenates the
                       top-level command and the subcommand
                       ("client-no-evict.md"), and only the FIRST hyphen is
                       the command/subcommand separator -- a subcommand's own
                       name can itself contain a hyphen ("client-no-evict.md"
                       -> "CLIENT NO-EVICT", not "CLIENT NO EVICT";
                       "cluster-count-failure-reports.md" ->
                       "CLUSTER COUNT-FAILURE-REPORTS"). Splitting on every
                       hyphen would silently corrupt exactly these names.
  groups.json          {group_id: {display, description}} -- group DISPLAY
                       names only, no per-command group membership. Without
                       that mapping (which valkey-doc's own site build gets
                       from the engine repo's src/commands/*.json, not from
                       this repo), every command here is typed uniformly as
                       "Command" rather than guessed at -- cosmetic metadata
                       only (entries.type feeds `+devdocs types`/`--type`,
                       never ref resolution), so this is a scope reduction
                       worth stating plainly rather than faking a mapping.
  topics/<slug>.md     guide pages, WITH real "title:"/"description:" YAML
                       front matter (a plain `key: value` pair per line --
                       parsed with a regex, not a YAML library: adding
                       PyYAML as a build dependency for two string fields
                       would be a heavier dependency than the value justifies,
                       and the same reasoning already governs every other
                       stdlib-only script in this pipeline).

Each command becomes its own PAGE with a single page-defining ENTRY
(anchor=None) -- the same "flat doc" shape devdocs-cli.py's cmd_show already
has a fallback for (used today by the Nix manual family), chosen because a
command page has no internal anchors of its own to scope into.
"""
import argparse
import json
import os
import re
import sys

import markdown as _markdown

FRONT_MATTER_RE = re.compile(r"^---\s*\n(.*?\n)---\s*\n(.*)$", re.S)
FRONT_MATTER_KV_RE = re.compile(r'^(\w[\w-]*):\s*(.*)$', re.M)
LICENSE_FILES = ("LICENSE", "COPYRIGHT")


def slug_to_command_name(slug):
    """"client-no-evict" -> "CLIENT NO-EVICT". Only the FIRST hyphen is the
    command/subcommand boundary -- see module docstring."""
    return slug.replace("-", " ", 1).upper()


def parse_front_matter(text):
    """Best-effort `key: value` extraction from a `---\\n...\\n---` block.
    Returns (fields_dict, body). A file with no front matter, or one this
    regex cannot parse, degrades to ({}, text) -- never fails the build."""
    m = FRONT_MATTER_RE.match(text)
    if not m:
        return {}, text
    fields = dict(FRONT_MATTER_KV_RE.findall(m.group(1)))
    return fields, m.group(2)


def markdown_to_html(text):
    return _markdown.markdown(text, extensions=["fenced_code", "tables", "sane_lists"])


def build(tree, slug, family, commit, license_, license_url, attribution,
          source_url, sqlite_path, licenses_out):
    from devdocs_sqlite import IndexWriter

    commands_dir = os.path.join(tree, "commands")
    if not os.path.isdir(commands_dir):
        sys.exit(f"{family}: no commands/ directory under {tree!r} -- wrong tree or layout changed upstream")

    writer = IndexWriter()
    type_counts = {}

    command_files = sorted(f for f in os.listdir(commands_dir) if f.endswith(".md"))
    for fn in command_files:
        cmd_slug = fn[: -len(".md")]
        name = slug_to_command_name(cmd_slug)
        with open(os.path.join(commands_dir, fn), encoding="utf-8") as f:
            body_md = f.read()
        html = f"<h1>{name}</h1>\n" + markdown_to_html(body_md)
        page_path = f"commands/{cmd_slug}".lower()
        writer.add_page(page_path, html)
        writer.add_entry(name, page_path, anchor=None, type_="Command")
        type_counts["Command"] = type_counts.get("Command", 0) + 1

    topics_dir = os.path.join(tree, "topics")
    topic_count = 0
    if os.path.isdir(topics_dir):
        for fn in sorted(os.listdir(topics_dir)):
            if not fn.endswith(".md"):
                continue  # topics/ also holds images (.png/.gif) referenced by the guides
            topic_slug = fn[: -len(".md")]
            with open(os.path.join(topics_dir, fn), encoding="utf-8") as f:
                raw = f.read()
            fields, body_md = parse_front_matter(raw)
            title = fields.get("title", topic_slug)
            html = f"<h1>{title}</h1>\n" + markdown_to_html(body_md)
            # Unlike commands/, topic slugs are NOT always lowercase upstream
            # (topics/ARM.md, topics/RDMA.md) -- pages.path must be, so
            # lowercase the PATH only; `title` (the entry's display name and
            # search text) keeps its real case.
            page_path = f"topics/{topic_slug}".lower()
            writer.add_page(page_path, html)
            writer.add_entry(title, page_path, anchor=None, type_="Guide")
            type_counts["Guide"] = type_counts.get("Guide", 0) + 1
            topic_count += 1

    for name, count in sorted(type_counts.items()):
        writer.add_type(name, name.lower(), count)

    os.makedirs(licenses_out, exist_ok=True)
    copied = []
    for fn in LICENSE_FILES:
        p = os.path.join(tree, fn)
        if os.path.isfile(p):
            with open(p, "rb") as f:
                data = f.read()
            with open(os.path.join(licenses_out, fn), "wb") as f:
                f.write(data)
            copied.append(fn)
    with open(os.path.join(licenses_out, f"{slug}-DECLARED-LICENSE.txt"), "w", encoding="utf-8") as f:
        f.write(
            f"slug: {slug}\nfamily: {family}\nsource: {source_url}\ncommit: {commit}\n"
            f"license: {license_}\nlicense_url: {license_url}\nattribution: {attribution}\n"
        )

    meta = {
        "slug": slug,
        "family": family,
        "name": family,
        "release": commit[:12],
        "mtime": "",
        "features": json.dumps({"names": True, "content": False}),
        "source_kind": "redisCommands",
        "source_url": source_url,
        "commit": commit,
        "license": license_,
        "license_url": license_url,
        "attribution": attribution,
    }
    writer.finish(sqlite_path, meta)
    print(f"{slug}: {len(command_files)} commands, {topic_count} topics", file=sys.stderr)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--tree", required=True, help="root of the fetched valkey-doc/redis-doc source tree")
    p.add_argument("--slug", required=True)
    p.add_argument("--family", required=True)
    p.add_argument("--commit", required=True)
    p.add_argument("--license", dest="license_", required=True)
    p.add_argument("--license-url", default="")
    p.add_argument("--attribution", default="")
    p.add_argument("--source-url", required=True)
    p.add_argument("--sqlite", required=True)
    p.add_argument("--licenses-out", required=True)
    args = p.parse_args()
    build(args.tree, args.slug, args.family, args.commit, args.license_,
          args.license_url, args.attribution, args.source_url, args.sqlite, args.licenses_out)


if __name__ == "__main__":
    main()
