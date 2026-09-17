"""Hermetic tests for the devdocs pipeline: devdocs_fixture.py's synthetic
tarball, through build-index.py, against the real +devdocs CLI. No network,
no real DevDocs data. Wired into checks.devdocs (modules/devdocs.nix), NOT
into checks.ai-composition -- see that module's comment for why.

Usage: test_devdocs_cli.py CLI_SCRIPT [--online-blackhole URL]
  CLI_SCRIPT is the path to devdocs-cli.py to invoke via `python3 CLI_SCRIPT`.
"""
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
import devdocs_fixture  # noqa: E402

BUILD_INDEX = os.path.join(os.path.dirname(__file__), "..", "..", "_files", "devdocs", "build-index.py")


def run(cli, ddir, *args, env_extra=None, expect_ok=True):
    env = {**os.environ, "DEVDOCS_DIR": ddir}
    if env_extra:
        env.update(env_extra)
    p = subprocess.run(
        [sys.executable, cli, *args],
        capture_output=True, text=True, env=env, timeout=30,
    )
    if expect_ok and p.returncode != 0:
        raise AssertionError(f"{args} exited {p.returncode}\nstdout: {p.stdout}\nstderr: {p.stderr}")
    return p


def setup():
    tmp = tempfile.mkdtemp(prefix="devdocs-test-")
    fixture_dir = os.path.join(tmp, "fixture")
    tarball = devdocs_fixture.build(fixture_dir)
    ddir = os.path.join(tmp, "installed")
    os.makedirs(ddir)
    subprocess.run(
        [sys.executable, BUILD_INDEX, "--tarball", tarball, "--slug", "fixture~1",
         "--family", "fixture", "--sqlite", os.path.join(ddir, "fixture-1.sqlite")],
        check=True, capture_output=True, text=True,
    )
    with open(os.path.join(ddir, "catalog.json"), "w") as f:
        json.dump({"fixture~1": {"name": "Fixture", "release": "1.0"},
                   "rust": {"name": "Rust", "release": "1.0"}}, f)
    return ddir


def test_anchor_scoping_shrinks_the_answer(cli, ddir):
    scoped = run(cli, ddir, "show", "java.base/java/util/list#add(int,E)")
    whole = run(cli, ddir, "page", "fixture~1", "java.base/java/util/list")
    assert len(scoped.stdout) < len(whole.stdout) / 2, (
        f"anchor-scoped show ({len(scoped.stdout)}b) should be far smaller than "
        f"the whole page ({len(whole.stdout)}b) -- this is the entire point of anchor scoping"
    )
    assert "Inserts the specified element" in scoped.stdout
    assert "Appends the specified element" not in scoped.stdout, (
        "show scoped to add(int,E) leaked the OTHER overload's (add(E)'s) content"
    )


def test_generic_extraction_not_javadoc_specific(cli, ddir):
    # The Nix-manual shape: id sits on an <h2> nested inside <div><div>, not
    # on a container carrying the id directly. Extraction must climb OUT to
    # the enclosing <section> and stop before the NEXT sibling section.
    out = run(cli, ddir, "show", "fixture/manual/index#fixture-widget-spin").stdout
    assert "Spins the named widget" in out
    assert "How many times to spin it" in out
    assert "Stops the named widget" not in out, (
        "extraction for fixture-widget-spin leaked into the next section (fixture-widget-stop)"
    )


def test_fqn_resolution_literal_before_dotted(cli, ddir):
    # "java.base/java/util/list" contains a dot in the module prefix itself;
    # the literal-suffix check must run before the dots->slashes rewrite.
    a = run(cli, ddir, "show", "java.base/java/util/list#add(E)").stdout
    b = run(cli, ddir, "show", "java.util.List#add(E)").stdout
    assert a == b, "verbatim path and dotted-FQN resolution of the same member disagree"


def test_ambiguity_is_deterministic(cli, ddir):
    strict = run(cli, ddir, "show", "java.base/java/util/list#add", "--max-render", "1", expect_ok=False)
    assert strict.returncode == 4, f"expected exit 4 (ambiguous), got {strict.returncode}"
    assert "add(E)" in strict.stderr and "add(int,E)" in strict.stderr

    default = run(cli, ddir, "show", "java.base/java/util/list#add")
    assert default.returncode == 0
    assert "add(E)" not in default.stderr.replace("note:", "")  # rendered, not just listed
    assert default.stdout.count("---") >= 1, "expected both overloads separated by ---"
    assert "boolean add(E e)" in default.stdout
    assert "void add(int index, E element)" in default.stdout


def test_empty_result_names_the_population(cli, ddir):
    p = run(cli, ddir, "search", "totallyNotAThing", expect_ok=False)
    assert p.returncode == 1
    assert "entries searched" in p.stderr or "entries searched" in p.stdout


def test_failure_modes_stay_distinct(cli, ddir):
    unknown = run(cli, ddir, "types", "not-a-real-slug", expect_ok=False)
    assert unknown.returncode == 3, f"unknown slug should be exit 3, got {unknown.returncode}"

    known_not_installed = run(cli, ddir, "types", "rust", expect_ok=False)
    assert known_not_installed.returncode == 5, (
        f"catalog-known-but-not-installed slug should be exit 5, got {known_not_installed.returncode}"
    )

    # Corrupt a page's blob and confirm that reads as exit 3 (data fault),
    # never exit 1 (no match) -- a database fault must not look like "no hit".
    import shutil
    import sqlite3
    corrupt_dir = tempfile.mkdtemp(prefix="devdocs-corrupt-")
    shutil.copy(os.path.join(ddir, "fixture-1.sqlite"), os.path.join(corrupt_dir, "fixture-1.sqlite"))
    shutil.copy(os.path.join(ddir, "catalog.json"), os.path.join(corrupt_dir, "catalog.json"))
    conn = sqlite3.connect(os.path.join(corrupt_dir, "fixture-1.sqlite"))
    conn.execute("UPDATE pages SET html = ? WHERE path = 'java.base/java/util/list'", (b"not zlib data",))
    conn.commit()
    conn.close()
    corrupt = run(cli, corrupt_dir, "show", "java.base/java/util/list#add(E)", expect_ok=False)
    assert corrupt.returncode == 3, f"corrupt blob should be exit 3, got {corrupt.returncode}"
    assert corrupt.returncode != 1


def test_output_plumbing(cli, ddir):
    small_cap = run(cli, ddir, "page", "fixture~1", "java.base/java/util/list",
                     env_extra={"DEVDOCS_MAX_BYTES": "10"})
    assert "truncated" in small_cap.stderr

    out_fd, out_file = tempfile.mkstemp(prefix="devdocs-out-")
    os.close(out_fd)  # the CLI writes it; this test only needs the path
    exact = run(cli, ddir, "page", "fixture~1", "java.base/java/util/list", "--output", out_file)
    with open(out_file, "rb") as f:
        file_bytes = f.read()
    piped = run(cli, ddir, "page", "fixture~1", "java.base/java/util/list", "--output", "-",
                env_extra={"DEVDOCS_MAX_BYTES": "10"})  # cap must NOT apply to --output -
    assert piped.stdout.encode("utf-8") == file_bytes, "--output - must be byte-identical to --output FILE"
    assert f"{out_file}\t{len(file_bytes)}" in exact.stdout

    j = run(cli, ddir, "search", "add", "--format", "json", env_extra={"DEVDOCS_MAX_BYTES": "1"})
    json.loads(j.stdout)  # must parse even with a 1-byte cap: json is never truncated


def test_offline_stays_offline(cli, ddir):
    # A non-routable address as the online base: every NON---online path
    # must still succeed, proving there is no silent network fallback.
    r = run(cli, ddir, "show", "java.base/java/util/list#add(E)",
            env_extra={"DEVDOCS_ONLINE_BASE": "http://198.51.100.1:1"})
    assert r.returncode == 0

    search_online = run(cli, ddir, "search", "x", "--online", expect_ok=False)
    assert search_online.returncode == 3, "search --online must fail loud, DevDocs has no search API"


def test_builder_round_trip(ddir):
    conn_path = os.path.join(ddir, "fixture-1.sqlite")
    import sqlite3
    import zlib
    conn = sqlite3.connect(conn_path)
    entry_count = int(dict(conn.execute("SELECT key, value FROM meta"))["entry_count"])
    real_entries = conn.execute("SELECT count(*) FROM entries").fetchone()[0]
    skipped = json.loads(dict(conn.execute("SELECT key, value FROM meta"))["skipped_entries"])
    assert entry_count == real_entries + len(skipped), (
        "meta.entry_count must equal rows actually inserted plus rows skipped, "
        "or a silently dropped entry would go unnoticed"
    )
    zdict = conn.execute("SELECT value FROM meta WHERE key='zdict'").fetchone()[0]
    for path, blob, raw_bytes in conn.execute("SELECT path, html, raw_bytes FROM pages"):
        d = zlib.decompressobj(-15, zdict)
        out = d.decompress(blob) + d.flush()
        assert len(out) == raw_bytes, f"{path}: decompressed length does not match raw_bytes"


def main():
    cli = sys.argv[1]
    ddir = setup()
    tests = [
        (test_anchor_scoping_shrinks_the_answer, (cli, ddir)),
        (test_generic_extraction_not_javadoc_specific, (cli, ddir)),
        (test_fqn_resolution_literal_before_dotted, (cli, ddir)),
        (test_ambiguity_is_deterministic, (cli, ddir)),
        (test_empty_result_names_the_population, (cli, ddir)),
        (test_failure_modes_stay_distinct, (cli, ddir)),
        (test_output_plumbing, (cli, ddir)),
        (test_offline_stays_offline, (cli, ddir)),
        (test_builder_round_trip, (ddir,)),
    ]
    failed = 0
    for fn, fn_args in tests:
        try:
            fn(*fn_args)
            print(f"ok   {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL {fn.__name__}: {e}")
    if failed:
        sys.exit(1)
    print(f"{len(tests)} devdocs CLI tests passed")


if __name__ == "__main__":
    main()
