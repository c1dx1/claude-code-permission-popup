#!/bin/sh
# Renders the README screenshots from the demo requests in requests/.
set -eu
cd "$(dirname "$0")"
app=../../plugins/permission-popup/PermissionPopup.app/Contents/MacOS/permission-popup
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -O -target "$(uname -m)-apple-macos13.0" compose.swift -o "$work/compose"

shot() { # request appearance
    env -u CLAUDE_CODE_HOST_SESSION_ID PERMISSION_POPUP_SNAPSHOT="$work/$1-$2" PERMISSION_POPUP_APPEARANCE="$2" \
        "$app" -AppleLanguages '(en)' -muted NO < "requests/$1.json"
}
for theme in light dark; do shot command "$theme"; done
shot diff light
shot diff dark
shot danger light
shot danger-chain light

"$work/compose" ../card-light.png 28 "$work/command-light-card.png"
"$work/compose" ../card-dark.png 28 "$work/command-dark-card.png"
"$work/compose" ../card-danger.png 28 "$work/danger-light-card.png"
"$work/compose" ../stack.png 28 "$work/command-light-card.png" "$work/diff-light-card.png"
"$work/compose" ../window-command.png 24 "$work/command-light-window.png"
"$work/compose" ../window-diff.png 24 "$work/diff-dark-window.png"
"$work/compose" ../window-danger.png 24 "$work/danger-chain-light-window.png"
