# permission-popup

Claude Code plugin for macOS: a card in the corner of the screen with **Allow / Deny** for permission prompts.
Screenshots, installation, shortcuts, configuration and development notes are in the
[repository README](../../README.md).

## Files

- `hooks/hooks.json`: registers the `PermissionRequest` hook
- `bin/permission-popup`: the hook entry point; exits silently off macOS and builds the app if it is missing
- `Sources/Core.swift`: parsing, diff, danger detection, rules and grants, covered by `Tests/main.swift`
- `Sources/main.swift`: the card, the details window, shortcuts and the hook protocol
- `make-icon.swift`: draws the app icon
- `build.sh`, `test.sh`, `source-hash.sh`: build, test, and fingerprint the sources the app was built from
