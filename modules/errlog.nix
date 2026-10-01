{ ... }:
{
  # `+errlog CMD …` keeps a long or noisy command's stderr out of an agent's
  # context. Package and rule ship from the same aspect, so the rule only
  # reaches hosts that actually have the tool (same shape as modules/vault.nix).
  flake.modules.homeManager.errlog = { pkgs, ... }:
    let
      # Standard library only, so no uv header or lockfile. The interpreter is a
      # pinned store path, like mkZshScript in modules/nix-cache.nix: Nix puts its
      # shebang first and the source's own `#!/usr/bin/env python3` becomes a
      # comment, which is what lets the tests run the file directly.
      errlog = pkgs.writeTextFile {
        name = "+errlog";
        destination = "/bin/+errlog";
        executable = true;
        text = ''
          #!${pkgs.python3}/bin/python3
          ${builtins.readFile ./_files/errlog/errlog.py}
        '';
      };
    in
    {
      home.packages = [ errlog ];
      my.ai.extraRules = [ ./_files/errlog/rules/errlog.md ];
    };

  perSystem = { pkgs, ... }: {
    # Runs the suite with the same python3 the tool ships with.
    checks.errlog = pkgs.runCommand "errlog-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
      export PYTHONDONTWRITEBYTECODE=1
      cp ${./_files/errlog/errlog.py} errlog.py
      cp ${./_files/errlog/test_errlog.py} test_errlog.py
      python3 test_errlog.py
      touch $out
    '';
  };
}
