{ pkgs, ... }:
{
  homebrew.enable = true;
  homebrew.caskArgs = {
    appdir = "~/Applications";
    require_sha = true;
    no_quarantine = true;
  };
  homebrew.casks = [
    "1password"
    "brave-browser"
    "firefox"
    "google-chrome"
    "jetbrains-toolbox"
    "lm-studio"
    "localsend/localsend/localsend"
    "microsoft-office"
    "visual-studio-code"
  ];
  homebrew.masApps = {
    Amphetamine = 937984704;
  };
  homebrew.onActivation.cleanup = "uninstall";
}