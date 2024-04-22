
# MacOS

- `xcode-select --install`
- Give Terminal "Full Disk Access" (otherwise you'll get the error: "Defaults: Could not write to domain ...")
- Make Terminal a "Developer Tool"
- Configure sops encryption
- Install Nix
- Optional: Switch Nix to single user mode
- Re-check ownership of `/nix/store`
- `git-credential-manager install`
- `atuin login && atuin sync -f`
- Import Raycast settings
- Configure Velja Browser picker
- Install manually
  - YourKit Profiler
  - iTerm Shell Integration



```shell
# Rcmd: Assign "L" to launchpad
killall rcmd; plutil -insert appKeyAssignments.0 -string '{"app":{"path":"\\/System\\/Applications\\/Launchpad.app","switchCount":0,"originalName":"Launchpad","url":"file:\\/\\/\\/System\\/Applications\\/Launchpad.app\\/","identifier":"com.apple.launchpad.launcher","useCount":0},"key":"l","whenAlreadyFocusedAction":0,"index":0}' ~/Library/Containers/com.lowtechguys.rcmd/Data/Library/Preferences/com.lowtechguys.rcmd.plist; open /Applications/rcmd.app
```


# dotfiles
Dotfiles for Codespaces

