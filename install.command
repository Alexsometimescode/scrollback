#!/bin/zsh
# Double-click this to install Scrollback (Scrollback.app bundle).
#
# macOS quarantines anything downloaded from a browser and refuses to launch an
# app that is not notarised. This removes that flag from the app it ships beside,
# moves it to /Applications and opens it. Nothing else.
cd "$(dirname "$0")" || exit 1
print -r -- "Installing Scrollback…"

[[ -f Scrollback.app.zip && ! -d Scrollback.app ]] && ditto -x -k Scrollback.app.zip .
[[ -d Scrollback.app ]] || { print -r -- "Scrollback.app not found next to this script."; exit 1; }

xattr -dr com.apple.quarantine Scrollback.app 2>/dev/null
rm -rf /Applications/Scrollback.app
cp -R Scrollback.app /Applications/
xattr -dr com.apple.quarantine /Applications/Scrollback.app 2>/dev/null
open /Applications/Scrollback.app

print -r -- "Done. Scrollback is in your menu bar; click it to finish setup."
print -r -- "This window can be closed."
