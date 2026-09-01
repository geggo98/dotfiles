{ lib, inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.modules ];
  flake.modules = lib.mkDefault { };
  # Four systems, and two of them have no host yet. That is deliberate:
  # x86 Linux and x86 Darwin machines are expected, and the list is what keeps a
  # `nixosSystem` call from silently landing on `aarch64-darwin` — always set
  # `system` explicitly rather than relying on the caller. This note used to live
  # in infra/Plan.md Phase 3, which is done and gone; it is here now because this
  # is the line it explains.
  systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
}
