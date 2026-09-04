_current_version := `./scripts/current-version.sh`

default:
	@just --list

# Run the complete behavioral test suite with its dependencies supplied by Nix.
test:
	nix develop path:. -c prove -lr t

# Show the highest stable release tag. Before the first stable release, this is 0.39.0.
version:
	@echo "v{{_current_version}}"

# Bump and release: just release patch|minor|major
release bump:
	#!/usr/bin/env bash
	set -euo pipefail
	git diff --quiet && git diff --cached --quiet \
		|| { echo "Tracked changes must be committed before releasing"; exit 1; }
	git pull --rebase \
		|| { echo "Pull failed - resolve conflicts before releasing"; exit 1; }
	current="$(./scripts/current-version.sh)"
	new="$(./scripts/next-version.sh "$current" "{{bump}}")" \
		|| { echo "Usage: just release patch|minor|major"; exit 1; }
	git rev-parse --verify --quiet "refs/tags/v$new" >/dev/null \
		&& { echo "Tag v$new already exists"; exit 1; }
	echo "v$current -> v$new"
	read -r -p "Continue? [y/N] " confirm
	[[ "$confirm" =~ ^[Yy]$ ]] || exit 1
	./scripts/set-version.sh "$new"
	just test
	nix flake check path:. --print-build-logs
	git add tes3cmd flake.nix
	git commit -m "release v$new"
	git tag "v$new"
	git push origin HEAD "v$new"
	echo "Pushed v$new - release workflow will start"
	./scripts/watch-release-workflow.sh "$(git rev-parse HEAD)"
