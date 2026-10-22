# permission-popup

Claude Code plugin for macOS: a card in the corner of the screen with **Allow / Deny** for permission prompts.
Screenshots, installation and details are in the [repository README](../../README.md).

## Files

- `hooks/hooks.json`: registers the `PermissionRequest` hook
- `bin/permission-popup`: the hook entry point; exits silently off macOS and builds the app if it is missing
- `PermissionPopup.swift`: the card, the details window and the decision logic
- `make-icon.swift`: draws the app icon
- `build.sh`: builds `PermissionPopup.app` for Apple Silicon and Intel, macOS 13+

## Configuration

`PERMISSION_POPUP_TIMEOUT` sets how many seconds a card waits before handing the question to Claude Code's own prompt
(default 15).
