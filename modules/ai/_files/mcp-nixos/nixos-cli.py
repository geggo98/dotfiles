"""Command-line front end for the mcp-nixos query engine.

Why this exists: mcp-nixos is a stateless query aggregator over public HTTP
APIs (search.nixos.org, NixHub, FlakeHub, Noogle, the wiki, nix.dev, ...). Run
as an MCP server it costs one resident process per agent session — measured
2026-09-10, 15.2 MiB in each of nine concurrent Claude sessions, with no work
to show for it. As a CLI it costs nothing between calls.

It deliberately reimplements NOTHING. `mcp_nixos.server.nix` and
`.nix_versions` are FastMCP tool objects whose underlying coroutine is reachable
at `.fn`; this file parses arguments and calls them, so the output is the same
text the MCP server returned. That keeps ~3300 lines of upstream data-source
logic where it belongs.

Interface note: the subcommands mirror the MCP tool's `action` values one for
one, so anything written about the tool still applies here.
"""

import argparse
import asyncio
import sys


def _tool(name):
    """Return the plain coroutine behind a FastMCP tool object.

    FastMCP wraps the decorated function; `.fn` is the unwrapped callable.
    Falling back to the object itself keeps this working if a future version
    stops wrapping. If neither is callable we fail loudly rather than return
    something that only breaks at await time.
    """
    import mcp_nixos.server as server

    obj = getattr(server, name)
    fn = getattr(obj, "fn", None) or obj
    if not callable(fn):
        raise SystemExit(
            f"mcp_nixos.server.{name} is not callable ({type(obj).__name__}). "
            "The upstream API changed; this CLI needs updating."
        )
    return fn


def build_parser():
    p = argparse.ArgumentParser(
        prog="+nix-query",
        description="Query nixpkgs, NixOS/home-manager/darwin options, flakes, "
        "the binary cache and /nix/store paths.",
    )
    sub = p.add_subparsers(dest="action", required=True)

    def common(sp, *, query_help=None, query_required=True):
        if query_help is not None:
            sp.add_argument("query", nargs="?" if not query_required else None, help=query_help)
        sp.add_argument("--source", default="nixos",
                        help="nixos (default), home-manager, darwin, flakes, flakehub, "
                             "nixvim, nvf, wiki, nix-dev, noogle, nixhub")
        sp.add_argument("--type", default="packages", dest="type_",
                        help="packages|options|programs|flakes for search; package|option for info")
        sp.add_argument("--channel", default="unstable", help="unstable (default), stable, or e.g. 25.05")
        sp.add_argument("--limit", type=int, default=20, help="max results, 1-100")
        return sp

    common(sub.add_parser("search", help="keyword lookup"), query_help="search term")
    common(sub.add_parser("info", help="details for an exact name"), query_help="exact name")
    common(sub.add_parser("browse", help="walk an option hierarchy by prefix"), query_help="prefix path")
    common(sub.add_parser("stats", help="counts"), query_help="unused", query_required=False)
    common(sub.add_parser("channels", help="list channels"), query_help="unused", query_required=False)
    common(sub.add_parser("flake-inputs", help="inspect a flake's inputs"),
           query_help="input_name or input:path", query_required=False)
    common(sub.add_parser("store", help="read/list a /nix/store path"), query_help="absolute /nix/store path")

    c = common(sub.add_parser("cache", help="is it in the binary cache?"), query_help="package name")
    c.add_argument("--pkg-version", default="latest", help="package version (default: latest)")
    c.add_argument("--system", default="", help="e.g. x86_64-linux; empty for all")

    v = sub.add_parser("versions", help="version history from NixHub (which commit shipped X)")
    v.add_argument("package", help="package name")
    v.add_argument("--pkg-version", default="", help="find this specific version")
    v.add_argument("--limit", type=int, default=20)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)

    if args.action == "versions":
        fn = _tool("nix_versions")
        coro = fn(package=args.package, version=args.pkg_version, limit=args.limit)
    else:
        fn = _tool("nix")
        kwargs = dict(
            action=args.action,
            query=getattr(args, "query", None) or "",
            source=args.source,
            type=args.type_,
            channel=args.channel,
            limit=args.limit,
        )
        if args.action == "cache":
            kwargs["version"] = args.pkg_version
            kwargs["system"] = args.system
        coro = fn(**kwargs)

    sys.stdout.write(asyncio.run(coro).rstrip("\n") + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
