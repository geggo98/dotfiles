"""Build a synthetic valkey-doc-shaped source tree for the hermetic
build-redis-index.py test: commands/*.md (including a multi-hyphen
subcommand name, the "CLIENT NO-EVICT" case measured against the real
valkey-io/valkey-doc repo) and topics/*.md (with real YAML-ish front
matter).

Usage: redis_fixture.py OUTDIR
"""
import os
import sys

COMMANDS = {
    "get": "Get the value of `key`.\n\nReturns `nil` if the key does not exist.\n",
    "client-no-evict": (
        "Sets the client eviction mode for the current connection.\n\n"
        "## Examples\n\n```\nCLIENT NO-EVICT on\nOK\n```\n"
    ),
}

TOPICS = {
    "introduction": (
        "---\ntitle: Introduction\ndescription: What this is\n---\n\n"
        "This is the introduction topic, linking to [GET](../commands/get.md).\n"
    ),
}

LICENSE_TEXT = "Creative Commons Attribution-ShareAlike 4.0 International Public License\n(fixture text)\n"


def build(outdir):
    commands_dir = os.path.join(outdir, "commands")
    topics_dir = os.path.join(outdir, "topics")
    os.makedirs(commands_dir, exist_ok=True)
    os.makedirs(topics_dir, exist_ok=True)

    for slug, body in COMMANDS.items():
        with open(os.path.join(commands_dir, f"{slug}.md"), "w", encoding="utf-8") as f:
            f.write(body)

    for slug, body in TOPICS.items():
        with open(os.path.join(topics_dir, f"{slug}.md"), "w", encoding="utf-8") as f:
            f.write(body)

    with open(os.path.join(outdir, "LICENSE"), "w", encoding="utf-8") as f:
        f.write(LICENSE_TEXT)
    with open(os.path.join(outdir, "COPYRIGHT"), "w", encoding="utf-8") as f:
        f.write("Copyright fixture contributors\n")

    return outdir


if __name__ == "__main__":
    print(build(sys.argv[1]))
