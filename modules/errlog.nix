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
      errlog = pkgs.runCommand "errlog" { } ''
        mkdir -p $out/bin $out/libexec
        { echo '#!${pkgs.python3}/bin/python3'; cat ${./_files/errlog/errlog.py}; } > $out/libexec/errlog.py
        chmod +x $out/libexec/errlog.py
        # Python puts the resolved script directory on sys.path, so the shared
        # masker is found next to the script, through the bin/ symlink too.
        cp ${./_files/secret-mask/masker.py} $out/libexec/masker.py
        ln -s ../libexec/errlog.py "$out/bin/+errlog"
      '';
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
      cp ${./_files/secret-mask/masker.py} masker.py
      cp ${./_files/errlog/test_errlog.py} test_errlog.py
      python3 test_errlog.py
      touch $out
    '';
  };
}
