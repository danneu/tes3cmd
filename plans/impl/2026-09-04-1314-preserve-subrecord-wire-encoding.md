# Preserve Subrecord Wire Encoding

## Problem and desired outcome

Rewriting a decoded record currently re-encodes every subrecord, which can alter
valid wire bytes that the user did not modify. Rewrites should preserve every
untouched subrecord byte-for-byte while retaining strict codec verification.

## Decision

- Decoded subrecords retain their original wire bytes and decoded field values.
- Normal record encoding passes clean subrecords through unchanged and re-encodes
  new, explicitly dirty, or directly changed subrecords.
- Codec verification has an internal forced-reencode path that bypasses raw
  passthrough while retaining recorded wire conventions.
- Changed `ARMO.BNAM`, `CLOT.CNAM`, `GMST.NAME`, `SSCR.DATA`, and `SSCR.NAME`
  values retain the original presence or absence of a trailing NUL. New values
  retain the existing unterminated canonical encoding.
- The codec cache version advances from `0.3` to `0.4`.

## Invariants

- An untouched decoded subrecord is emitted byte-for-byte as read during a
  normal rewrite.
- Supported mutation paths cannot lose an intended field or header change due
  to raw passthrough.
- Direct changes to generated fields are detected even without an explicit
  dirty marker once their record is encoded.
- Strict `-testcodec` always exercises encoders and reports genuine codec
  mismatches.
- Cache data decoded under an older codec version is rejected.

## Proof obligations

- Generated fixtures prove strict round trips for terminated and unterminated
  forms of all five asymmetric strings.
- Behavioral tests prove untouched wire bytes survive unrelated edits, changed
  asymmetric strings retain their convention, and newly created asymmetric
  strings remain unterminated.
- Behavioral tests cover `set`, `modify --replace`, header edits, and CELL edits.
- A deliberately incorrect codec proves forced re-encoding still detects a
  mismatch.
- Master and aggregate cache tests prove codec-version mismatch invalidation.
- Syntax checks, the complete suite, and strict real-plugin round trips pass.

## Non-goals

- `--ignore-cruft` will not accept length changes.
- Application release metadata and the application version will not change.
- The Spanish plugin sources and outputs will not be modified.
- `TODO.md` remains untracked and is not committed.

## Implementation discretion

- Internal metadata names and test fixture organization are left to
  implementation.
