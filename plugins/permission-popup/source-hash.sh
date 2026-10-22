#!/bin/sh
# Hash of everything the app is built from.
set -eu
cd "$(dirname "$0")"
cat Sources/*.swift make-icon.swift Info.plist build.sh | shasum -a 256 | cut -d' ' -f1
