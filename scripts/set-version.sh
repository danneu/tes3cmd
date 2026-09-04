#!/usr/bin/env bash
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: set-version.sh X.Y.Z" >&2
    exit 1
fi

root="${2:-$(cd "$(dirname "$0")/.." && pwd)}"

TES3CMD_RELEASE_VERSION="$version" perl -pi -e \
    's/^(\s*\$::VERSION = ")[^"]+(";\s*)$/$1$ENV{TES3CMD_RELEASE_VERSION}$2/' \
    "$root/tes3cmd"
TES3CMD_RELEASE_VERSION="$version" perl -pi -e \
    's/^(\s*version = ")[^"]+(";\s*)$/$1$ENV{TES3CMD_RELEASE_VERSION}$2/' \
    "$root/flake.nix"

program_version="$(perl "$root/tes3cmd" --version)"
if [[ "$program_version" != "tes3cmd $version" ]]; then
    echo "tes3cmd version update failed: $program_version" >&2
    exit 1
fi

flake_versions="$(grep -Ec "^[[:space:]]+version = \"$version\";[[:space:]]*$" "$root/flake.nix")"
if [[ "$flake_versions" != 1 ]]; then
    echo "flake version update failed" >&2
    exit 1
fi
