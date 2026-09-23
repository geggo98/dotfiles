{ inputs, ... }:
{
  # AGENTS.md doubles as Codex's project doc, and Codex truncates it SILENTLY
  # past `project_doc_max_bytes` (32768, the codex 0.156.1 compiled-in
  # default) -- measured five times in ~/.codex/logs_2.sqlite as "project doc
  # exceeds remaining budget; truncating … remaining_bytes=32768" against this
  # repo's AGENTS.md before it was split into docs/*.md, at a point where the
  # file had grown past 150 KB. Claude Code's own warning threshold scales
  # with context window (max(40000, window * 0.05 * 3) chars) and is looser
  # at 1M context, so Codex's fixed byte budget is the one worth building a
  # check against -- it is the earliest one to silently drop content.
  #
  # This check exists to catch the next regrowth before it repeats that
  # silent-truncation failure: `just check` fails loudly, with the current
  # size and the fix, instead of a future Codex session quietly never seeing
  # half the file again.
  perSystem = { system, ... }:
    let
      pkgs = import inputs.nixpkgs { inherit system; };
      maxBytes = 32768;
    in
    {
      checks.agents-md-budget = pkgs.runCommand "agents-md-budget-check"
        { nativeBuildInputs = [ pkgs.perl ]; } ''
        cp ${../AGENTS.md} AGENTS.md
        cp -r ${../docs} docs
        perl ${./_files/agents-md-check/check.pl} AGENTS.md ${toString maxBytes}
        touch $out
      '';
    };
}
