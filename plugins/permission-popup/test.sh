#!/bin/sh
set -eu
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sources/Core.swift Tests/main.swift -o "$work/tests"
"$work/tests"
