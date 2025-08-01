{ ... }:
{
  imports = [
    ../../modules/homebrew-common.nix
  ];

  homebrew.brews = [
    "hashicorp/tap/boundary"
  ];
  homebrew.casks = [
    "aptakube"
    "bleunlock" # Unlock Mac based on mobile phone presence. https://github.com/ts1/BLEUnlock
    "hashicorp/tap/hashicorp-boundary-desktop"
    "cursor"
    "Dropbox"
    "git-credential-manager" # The version in Nix doesn't find its Dotnet SDK
    "languagetool"
    "openvpn-connect"
    "postman"
    "postman-cli"
    "slack" # Also available via the Mac App Store
    "tunnelblick"

    # Manual install:
    # YourKit Profiler
    # iTerm Shell Integration
  ];
  homebrew.masApps = {
  };
}