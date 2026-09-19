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
import javadoc_fixture  # noqa: E402
import redis_fixture  # noqa: E402

_DEVDOCS_DIR = os.path.join(os.path.dirname(__file__), "..", "..", "_files", "devdocs")
BUILD_INDEX = os.path.join(_DEVDOCS_DIR, "build-index.py")
BUILD_JAVADOC_INDEX = os.path.join(_DEVDOCS_DIR, "build-javadoc-index.py")
BUILD_REDIS_INDEX = os.path.join(_DEVDOCS_DIR, "build-redis-index.py")


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


def run_builder(*args):
    p = subprocess.run([sys.executable, *args], capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        raise AssertionError(f"{args} exited {p.returncode}\nstdout: {p.stdout}\nstderr: {p.stderr}")
    return p


def setup():
    tmp = tempfile.mkdtemp(prefix="devdocs-test-")
    ddir = os.path.join(tmp, "installed")
    os.makedirs(ddir)

    fixture_dir = os.path.join(tmp, "fixture")
    tarball = devdocs_fixture.build(fixture_dir)
    run_builder(BUILD_INDEX, "--tarball", tarball, "--slug", "fixture~1",
                "--family", "fixture", "--sqlite", os.path.join(ddir, "fixture-1.sqlite"))

    javadoc_dir = javadoc_fixture.build(os.path.join(tmp, "javadoc"))
    run_builder(BUILD_JAVADOC_INDEX, "--archive", javadoc_dir, "--slug", "fixture-javadoc",
                "--family", "fixture-javadoc", "--release", "1.0", "--license", "Apache-2.0",
                "--source-url", "file://fixture", "--sqlite", os.path.join(ddir, "fixture-javadoc.sqlite"),
                "--licenses-out", os.path.join(tmp, "javadoc-licenses"))

    redis_dir = redis_fixture.build(os.path.join(tmp, "redis"))
    run_builder(BUILD_REDIS_INDEX, "--tree", redis_dir, "--slug", "fixture-redis",
                "--family", "fixture-redis", "--commit", "deadbeef1234", "--license", "CC-BY-SA-4.0",
                "--source-url", "file://fixture", "--sqlite", os.path.join(ddir, "fixture-redis.sqlite"),
                "--licenses-out", os.path.join(tmp, "redis-licenses"))

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


def _content_env(tag):
    # A dedicated tmp cache dir per test, never the real ~/.cache -- hermetic
    # even when this file is run standalone outside the Nix sandbox (which
    # sets HOME=$TMPDIR itself; this is defense in depth, matching AGENTS.md's
    # general preference for explicit inputs over relying on ambient state).
    return {"XDG_CACHE_HOME": tempfile.mkdtemp(prefix=f"devdocs-cache-{tag}-")}


def test_content_search_finds_wording_name_search_misses(cli, ddir):
    # "Appends" names List.add(E)'s BEHAVIOUR, never its own entry name --
    # exactly the gap that motivated this tier (`search trim` cannot find
    # `String.strip()`). A plain name search must still miss it.
    name_only = run(cli, ddir, "search", "Appends", "--doc", "fixture~1", expect_ok=False)
    assert name_only.returncode == 1, "name-only search matched a WORD -- fixture assumption broke"

    env = _content_env("wording")
    content = run(cli, ddir, "search", "Appends", "--content", "--doc", "fixture~1", env_extra=env)
    assert "List.add()" in content.stdout
    assert "id=" not in content.stdout, "the id-bearing tag itself leaked into the snippet"


def test_content_search_cache_is_built_once_and_reused(cli, ddir):
    env = _content_env("reuse")
    first = run(cli, ddir, "search", "Appends", "--content", "--doc", "fixture~1", env_extra=env)
    assert "building content index" in first.stderr

    cache_root = os.path.join(env["XDG_CACHE_HOME"], "devdocs")
    fts_files = [f for r, _, fs in os.walk(cache_root) for f in fs if f.endswith(".fts")]
    assert fts_files, f"no .fts cache file appeared under {cache_root}"
    assert not any(f.endswith(".tmp") or ".tmp." in f for f in fts_files), (
        "a temp file was left where the final .fts should be -- os.replace() did not fire"
    )

    second = run(cli, ddir, "search", "Appends", "--content", "--doc", "fixture~1", env_extra=env)
    assert "building content index" not in second.stderr, "cache hit rebuilt the index anyway"
    assert second.stdout == first.stdout


def test_content_index_rebuild_sweeps_foreign_pid_stale_temps(cli, ddir):
    # A build killed mid-write (the activation hook's `timeout`, no cleanup
    # handler on SIGTERM) leaves `<slug>.fts.tmp.<PID>` behind. A LATER
    # rebuild runs under a DIFFERENT pid, so it must not only avoid tripping
    # over such a file -- it must actually remove it, or every crash leaks
    # one file forever. Fabricate two, from two fake "other" pids.
    env = _content_env("stale-sweep")
    run(cli, ddir, "warm-content", "--doc", "fixture~1", env_extra=env)

    cache_root = os.path.join(env["XDG_CACHE_HOME"], "devdocs")
    final = next(
        os.path.join(r, f) for r, _, fs in os.walk(cache_root) for f in fs
        if f.endswith(".fts")
    )
    stale = [final + ".tmp.111111", final + ".tmp.222222"]
    for s in stale:
        with open(s, "w") as f:
            f.write("garbage from a killed build")

    rebuilt = run(cli, ddir, "warm-content", "--doc", "fixture~1", "--force", env_extra=env)
    assert "1 built, 0 already cached, 0 errors" in rebuilt.stdout, "rebuild over an existing index must not fail"
    assert not any(os.path.exists(s) for s in stale), "foreign-pid stale temp files were not swept"
    assert os.path.exists(final), "the real index must still be there after the rebuild"


def test_content_search_json_and_exit_codes(cli, ddir):
    env = _content_env("json")
    ok = run(cli, ddir, "search", "Appends", "--content", "--doc", "fixture~1",
             "--format", "json", env_extra=env)
    payload = json.loads(ok.stdout)
    assert payload and payload[0]["doc"] == "fixture~1" and payload[0]["desc"], (
        "content search JSON must carry doc/name/desc, matching the name-only tier's shape"
    )

    miss = run(cli, ddir, "search", "zzz_no_such_word_anywhere", "--content", "--doc", "fixture~1",
               env_extra=env, expect_ok=False)
    assert miss.returncode == 1, "content search miss must be exit 1, same contract as the name tier"
    assert "description text" in miss.stderr


def test_warm_content_classifies_built_vs_skipped(cli, ddir):
    env = _content_env("warm")
    first = run(cli, ddir, "warm-content", "--doc", "fixture~1", env_extra=env)
    assert "1 built, 0 already cached, 0 errors" in first.stdout

    second = run(cli, ddir, "warm-content", "--doc", "fixture~1", env_extra=env)
    assert "0 built, 1 already cached, 0 errors" in second.stdout, (
        "a re-run without --force must SKIP an existing cache file, not rebuild it"
    )

    forced = run(cli, ddir, "warm-content", "--doc", "fixture~1", "--force", env_extra=env)
    assert "1 built, 0 already cached, 0 errors" in forced.stdout, "--force must rebuild anyway"


def test_offline_stays_offline(cli, ddir):
    # A non-routable address as the online base: every NON---online path
    # must still succeed, proving there is no silent network fallback.
    r = run(cli, ddir, "show", "java.base/java/util/list#add(E)",
            env_extra={"DEVDOCS_ONLINE_BASE": "http://198.51.100.1:1"})
    assert r.returncode == 0

    search_online = run(cli, ddir, "search", "x", "--online", expect_ok=False)
    assert search_online.returncode == 3, "search --online must fail loud, DevDocs has no search API"


def _round_trip_one_db(path):
    import sqlite3
    import zlib
    conn = sqlite3.connect(path)
    zdict = conn.execute("SELECT value FROM meta WHERE key='zdict'").fetchone()[0]
    for p, blob, raw_bytes in conn.execute("SELECT path, html, raw_bytes FROM pages"):
        d = zlib.decompressobj(-15, zdict)
        out = d.decompress(blob) + d.flush()
        assert len(out) == raw_bytes, f"{path}:{p}: decompressed length does not match raw_bytes"
    conn.close()


def test_builder_round_trip(ddir):
    conn_path = os.path.join(ddir, "fixture-1.sqlite")
    import sqlite3
    conn = sqlite3.connect(conn_path)
    entry_count = int(dict(conn.execute("SELECT key, value FROM meta"))["entry_count"])
    real_entries = conn.execute("SELECT count(*) FROM entries").fetchone()[0]
    skipped = json.loads(dict(conn.execute("SELECT key, value FROM meta"))["skipped_entries"])
    assert entry_count == real_entries + len(skipped), (
        "meta.entry_count must equal rows actually inserted plus rows skipped, "
        "or a silently dropped entry would go unnoticed"
    )
    conn.close()
    for name in ("fixture-1.sqlite", "fixture-javadoc.sqlite", "fixture-redis.sqlite"):
        _round_trip_one_db(os.path.join(ddir, name))


# --------------------------------------------------------------------------
# build-javadoc-index.py: the Maven-javadoc / Gradle-docs source kind
# --------------------------------------------------------------------------

def test_javadoc_anchor_is_percent_decoded(cli, ddir):
    # {"l": "Widget()", "u": "%3Cinit%3E()"} must resolve as "<init>()",
    # matching the real id="&lt;init&gt;()" HTMLParser hands back already
    # char-reference-unescaped -- see javadoc_index.member_anchor.
    out = run(cli, ddir, "show", "fx.Widget#<init>()", "--doc", "fixture-javadoc").stdout
    assert "Creates a new Widget" in out


def test_javadoc_u_field_wins_over_l(cli, ddir):
    # The real anchor is the fully-qualified "u" form; "l" (simple types) is
    # only ever a display label.
    out = run(cli, ddir, "show", "fx.Widget#spin(int,java.lang.String)", "--doc", "fixture-javadoc").stdout
    assert "Spins the widget" in out
    search = run(cli, ddir, "search", "spin", "--doc", "fixture-javadoc").stdout
    assert "spin(int,java.lang.String)" in search, "the stored ref must use the u-form anchor, not the l-form"


def test_javadoc_nested_class_resolves_by_name(cli, ddir):
    # A nested class ("Widget.Spinner") is itself a page-defining entry; the
    # CLI's dotted-guess-split preprocessor must not pre-empt this by
    # treating it as (class=Widget, member=Spinner) before resolve_head ever
    # gets the whole ref.
    bare = run(cli, ddir, "show", "Widget.Spinner", "--doc", "fixture-javadoc")
    assert bare.returncode == 0
    fqn = run(cli, ddir, "show", "fx.Widget.Spinner#go()", "--doc", "fixture-javadoc")
    assert fqn.returncode == 0
    assert "Starts the nested spinner" in fqn.stdout


def test_javadoc_member_kind_derived(cli, ddir):
    # Member kind comes from the ENCLOSING <section id="...-detail">, not
    # the per-member <section class="detail"> (whose class is always the
    # literal string "detail").
    types_out = run(cli, ddir, "types", "fixture-javadoc").stdout
    for kind in ("Method", "Constructor", "Enum Constant"):
        assert kind in types_out, f"{kind} missing from types output: {types_out}"
    filtered = run(cli, ddir, "search", "spin", "--doc", "fixture-javadoc", "--type", "Method").stdout
    assert "spin" in filtered


def test_javadoc_missing_anchor_is_recorded_not_fatal(cli, ddir):
    import sqlite3
    conn = sqlite3.connect(os.path.join(ddir, "fixture-javadoc.sqlite"))
    missing = json.loads(dict(conn.execute("SELECT key, value FROM meta"))["missing_anchors"])
    assert len(missing) == 1 and missing[0].endswith("#ghost()"), missing
    hit = conn.execute("SELECT 1 FROM entries WHERE anchor='ghost()'").fetchone()
    conn.close()
    assert hit is None, "an entry with no matching HTML anchor must not be inserted"


def test_javadoc_without_search_index_fails_loudly():
    tmp = tempfile.mkdtemp(prefix="devdocs-test-badjavadoc-")
    bad_dir = os.path.join(tmp, "javadoc-bad")
    javadoc_fixture.build(bad_dir, with_member_index=False)
    p = subprocess.run(
        [sys.executable, BUILD_JAVADOC_INDEX, "--archive", bad_dir, "--slug", "bad",
         "--family", "bad", "--license", "Apache-2.0", "--source-url", "file://bad",
         "--sqlite", os.path.join(tmp, "bad.sqlite"),
         "--licenses-out", os.path.join(tmp, "bad-licenses")],
        capture_output=True, text=True, timeout=30,
    )
    assert p.returncode != 0, "a javadoc build with no member-search-index.js must fail, not emit an empty doc"
    assert "member-search-index" in p.stderr or "member-search-index" in p.stdout


def test_javadoc_page_is_main_only(cli, ddir):
    out = run(cli, ddir, "page", "fixture-javadoc", "fx/widget").stdout
    assert "navigation chrome" not in out
    assert "footer chrome" not in out


# --------------------------------------------------------------------------
# build-redis-index.py: the Valkey/Redis commands source kind
# --------------------------------------------------------------------------

def test_redis_flat_doc_round_trip(cli, ddir):
    out = run(cli, ddir, "show", "GET", "--doc", "fixture-redis").stdout
    assert "Get the value of" in out
    assert "nil" in out


def test_redis_multi_hyphen_subcommand_name(cli, ddir):
    # "client-no-evict.md" must become "CLIENT NO-EVICT", not "CLIENT NO
    # EVICT" -- only the FIRST hyphen is the command/subcommand boundary.
    out = run(cli, ddir, "show", "CLIENT NO-EVICT", "--doc", "fixture-redis").stdout
    assert "eviction mode" in out
    assert "```" in out or "CLIENT NO-EVICT on" in out, "fenced example block did not render"


def test_redis_topic_frontmatter_parsed(cli, ddir):
    out = run(cli, ddir, "show", "Introduction", "--doc", "fixture-redis").stdout
    assert "title: Introduction" not in out, "raw front matter leaked into the rendered body"
    assert "linking to" in out


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
        (test_content_search_finds_wording_name_search_misses, (cli, ddir)),
        (test_content_search_cache_is_built_once_and_reused, (cli, ddir)),
        (test_content_index_rebuild_sweeps_foreign_pid_stale_temps, (cli, ddir)),
        (test_content_search_json_and_exit_codes, (cli, ddir)),
        (test_warm_content_classifies_built_vs_skipped, (cli, ddir)),
        (test_offline_stays_offline, (cli, ddir)),
        (test_builder_round_trip, (ddir,)),
        (test_javadoc_anchor_is_percent_decoded, (cli, ddir)),
        (test_javadoc_u_field_wins_over_l, (cli, ddir)),
        (test_javadoc_nested_class_resolves_by_name, (cli, ddir)),
        (test_javadoc_member_kind_derived, (cli, ddir)),
        (test_javadoc_missing_anchor_is_recorded_not_fatal, (cli, ddir)),
        (test_javadoc_without_search_index_fails_loudly, ()),
        (test_javadoc_page_is_main_only, (cli, ddir)),
        (test_redis_flat_doc_round_trip, (cli, ddir)),
        (test_redis_multi_hyphen_subcommand_name, (cli, ddir)),
        (test_redis_topic_frontmatter_parsed, (cli, ddir)),
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
