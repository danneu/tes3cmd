# Package tes3cmd with Nix

## Problem and desired outcome

The existing flake supplies development dependencies and tests but does not
produce an installable `tes3cmd` command. Users on macOS and Linux should be
able to build, run, and install the command directly from the flake.

## Decision

- Publish `tes3cmd` as both the named and default package for Apple Silicon
  macOS and ARM and x86_64 Linux.
- The package uses Nix's Perl runtime and installs the command on `PATH` without
  producing platform-specific binary bundles.
- Keep the current pre-release application version until release preparation.
- Document local flake build, run, and profile-install workflows.

## Invariants

- Packaging does not change tes3cmd's runtime behavior.
- The installed command does not depend on `/usr/bin/perl`.
- `nix flake check` verifies both the behavioral suite and the installed
  command.

## Proof obligations

- The default package builds successfully on the current macOS system.
- The installed command runs and reports the current application version.
- All flake checks and formatting checks pass.

## Non-goals

- Windows packaging and standalone executables are excluded.
- Application release metadata, tags, branches, and `~/world` integration are
  deferred to later approved steps.

## Implementation discretion

- The derivation and smoke-check structure are left to implementation.

## Implementation notes

- Intel macOS was removed from the existing system matrix because the pinned
  Nixpkgs revision no longer supports `x86_64-darwin`; retaining it would
  require a separate older Nixpkgs input.
