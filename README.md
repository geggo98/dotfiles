# dotfiles
Dotfiles for Codespaces

```shell
# Rcmd: Assign "L" to launchpad
killall rcmd; plutil -insert appKeyAssignments.0 -string '{"app":{"path":"\\/System\\/Applications\\/Launchpad.app","switchCount":0,"originalName":"Launchpad","url":"file:\\/\\/\\/System\\/Applications\\/Launchpad.app\\/","identifier":"com.apple.launchpad.launcher","useCount":0},"key":"l","whenAlreadyFocusedAction":0,"index":0}' ~/Library/Containers/com.lowtechguys.rcmd/Data/Library/Preferences/com.lowtechguys.rcmd.plist; open /Applications/rcmd.app
````
