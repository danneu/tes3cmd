#!/usr/bin/env bash
# Print the highest stable vX.Y.Z tag. The fallback makes the first stable
# release of the 0.40 prerelease line a minor bump from 0.39.0.
set -euo pipefail

version="$({
    git tag --list --sort=-version:refname 'v*' \
        | sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+)$/\1/p'
} | head -n 1)"

printf '%s\n' "${version:-0.39.0}"
