{ ... }:
{
  # Match the formatter `just fmt` and the pre-commit hook already use,
  # so `nix fmt` produces a diff-free result on already-formatted files
  # instead of reformatting the whole tree to a different style.
  perSystem = { pkgs, ... }: {
    formatter = pkgs.nixpkgs-fmt;
  };
}
