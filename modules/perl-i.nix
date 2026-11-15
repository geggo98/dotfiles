{ ... }:
{
  # `+perl-i -pe '…' -- FILE…` runs `perl -i` after copying every file into a
  # fresh backup directory under $TMPDIR/perl-i. Same packaging as
  # modules/errlog.nix: standard library only, interpreter pinned by Nix.
  flake.modules.homeManager.perl-i = { pkgs, ... }:
    let
      perl-i = pkgs.runCommand "perl-i" { } ''
        mkdir -p $out/bin $out/libexec
        { echo '#!${pkgs.python3}/bin/python3'; cat ${./_files/perl-i/perl-i.py}; } > $out/libexec/perl-i.py
        chmod +x $out/libexec/perl-i.py
        ln -s ../libexec/perl-i.py "$out/bin/+perl-i"
      '';
    in
    {
      home.packages = [ perl-i ];
    };

  perSystem = { pkgs, ... }: {
    # Runs the suite with the same python3 the tool ships with. The tests call
    # the system perl, so it must be on PATH inside the sandbox.
    checks.perl-i = pkgs.runCommand "perl-i-check" { nativeBuildInputs = [ pkgs.python3 pkgs.perl ]; } ''
      export PYTHONDONTWRITEBYTECODE=1
      cp ${./_files/perl-i/perl-i.py} perl-i.py
      cp ${./_files/perl-i/test_perl_i.py} test_perl_i.py
      python3 test_perl_i.py
      touch $out
    '';
  };
}
