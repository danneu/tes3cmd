# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

tes3cmd is a command line tool for examining and modifying plugins (.esp/.esm) for
Morrowind (TES3). The entire program is one Perl script, `tes3cmd` (~9500 lines).
There is no build system, no test suite, and no module layout; `Docs/Notes.txt` is
the author's TODO list and `ChangeLog` summarizes releases.

## Commands

```sh
perl -c tes3cmd                      # syntax check (the only "build" step)
perl tes3cmd help                    # list commands; `help <command>` for one
perl tes3cmd dump --debug foo.esp    # --debug/-d, --verbose/-v, --assert are global
perl tes3cmd -testcodec foo.esp      # decode+re-encode every record, report mismatches
perl tes3cmd -shell                  # Perl REPL with TES3 packages loaded
pp -o tes3cmd.exe tes3cmd            # Windows build with Par::Packer
```

The closest thing to a test is `-testcodec`: it round-trips each subrecord through
decode/encode and prints CODEC FAILURE on any byte difference. Run it against a real
plugin after touching `@RECDEFS`. Use `--ignore-cruft` to tolerate trailing junk and
`-x TYPE` to exclude a subrecord type.

Note that `DBG`, `ASSERT`, `VERBOSE`, and `WRAP` are compile-time constants set in
`BEGIN` blocks by scanning `@ARGV`, so they must appear on the command line, not be
set from code.

## Runtime environment

`TES3::Util::find_morrowind()` walks up from the cwd looking for a directory containing
both `Data Files` and `Morrowind.ini`. If found, `$MWDIR/tes3cmd/` is created and used
for backups and `cache/*.cache` (Storable dumps of master records). If not found, the
tool warns, sets everything to `.`, and disables caching. Running from any directory
outside a Morrowind install therefore works but with "reduced functionality"
(no load order, `--active`, master lookups).

## Architecture of the single file

Packages appear in this order:

1. **`Util`** (line ~169): `err/dbg/msg/prn/abort/assert`, file helpers.
2. **`TES3::Util`**: Morrowind install discovery, `Morrowind.ini` read/write
   (`read_gamefiles`/`write_gamefiles`, deliberately tolerant hand-rolled parser),
   `load_order`.
3. **`TES3`** (line ~470): symbolic-name tables (`%AIDT_FLAGS`, `%ARMOR_TYPE`,
   `%SKILL`, ...) referenced by the codec via `lookup` / `symflags` options.
4. **`TES3::Record`** (line ~1180): the codec. `@RECDEFS` (line ~1521 to ~2931) is a
   declarative table: one entry per record type, each listing its subrecord types with
   `[fieldname, pack-format, {options}]` triples. `generate_classes()` walks it at
   startup and uses glob assignment to synthesize a class per record type
   (`ACTI`, `NPC_`, ...) inheriting from `TES3::Record`, plus a class per subrecord
   (`ACTI::NAME`) with `decode`/`encode`/`tostr` methods. Entries can override any of
   those with custom subs (see `@RD_reference`, the ARMO `AODT` tostr). Adding or
   fixing a record format means editing `@RECDEFS`, not writing a class.
   Records are lazy: `new_from_input` reads raw bytes, `decode()` parses on demand,
   and `_modified_` controls whether `write_rec` re-encodes or emits the original buffer.
5. **`LEVC` / `LEVI`**: `merge` methods used by multipatch for leveled lists.
6. **`main`** (line ~3848): globals, `%COMMAND` dispatch table, I/O, and `cmd_*` subs.

### Command dispatch

`%COMMAND` (line ~4736) maps a command name to `{ description, options, preprocess,
process, postprocess, usage }`. `options` is a Getopt::Long spec (usually
`@STDOPT` plus `@MODOPT` for modifying commands); bare option names bind to the
matching `$opt_*` global declared near the top of the file. `tes3cmd_main` parses
options, expands globs, applies `--ignore-plugin` and `--active`, calls `get_wanted()`
to compile `--type/--id/--flag` selectors, then runs `preprocess(@plugins)`,
`process($plugin)` once per plugin, and `postprocess(@plugins)`. Names not in
`%COMMAND` are tried as user extension files (`foo` or `foo.pl`) loaded with
`load_perl`, which `eval`s them and expects a `%COMMAND`-style hashref back.

The `usage` string is the help text; `help` reads `description` and `usage`
from the table, so a new command needs nothing else registered.

### Plugin processing loop

Almost every command is built on two helpers:

- `process_plugin_for_input($plugin, $fun)`: stream records, call
  `$fun->($rectype, $tr)` for each.
- `process_plugin_for_update($plugin, $fun, $prefix)`: same, but writes to a temp
  file. The callback's return value decides the outcome: `undef` deletes the record,
  a false value passes the original through unchanged, and a record object writes
  that (re-encoded) record. `fix_output` then renames over the original with a
  backup in `$opt_backup_dir`, or writes to `$prefix$plugin` when a prefix is given
  (e.g. `-testcodec` writes `test_foo.esp`).

`rec_match` applies the `--type`, `--id`, `--exact-id`, `--flag`, `--match`,
`--no-match`, `--interior/--exterior`, and instance selectors; commands like
`dump`, `delete`, `modify`, and `run` all go through it.

## Related repo

`../tes3-es` holds the Spanish translation plugins unpacked as JSON, with a
justfile that uses tes3conv for esp<->JSON and this script (via the relative
path `../tes3cmd/tes3cmd`) for `just check` and ad hoc `dump`/`diff`. Changes
to this script should keep `dump` and `diff` working when invoked from another
directory with no Morrowind install present (the "functionality reduced" path).

## Conventions

- Use Conventional Commits for all commit messages going forward.
- Tabs for indentation (existing file uses hard tabs at 8 columns).
- Bump `$::VERSION` in the top `BEGIN` block and add a `ChangeLog` entry for releases.
- Record and subrecord type names are always 4 uppercase chars (`NPC_`, not `NPC`);
  user input is uppercased and `NPC` is special-cased as shorthand.
- Field names in `@RECDEFS` are user-facing (they appear in `dump --format` and in
  `modify` expressions), so renaming one is a compatibility change.
