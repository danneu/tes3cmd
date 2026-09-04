# tes3cmd

tes3cmd is a command-line tool for examining and modifying TES3 plugin files
(`.esp`, `.esm`, and `.ess`) for The Elder Scrolls III: Morrowind.

All credit for tes3cmd goes to
[John Moonsugar's original project](https://github.com/john-moonsugar/tes3cmd).
I have just polished it by improving its tests, safety, behavior, and
documentation.

This repository currently contains a pre-release version. Keep independent
backups of important plugins and save games, especially when using modifying
commands.

## Installation

tes3cmd is a single Perl script. Run it directly on a system where the script
is executable, or invoke it through Perl:

```sh
chmod +x tes3cmd
./tes3cmd --version

# Equivalent when the executable bit or shebang is unavailable:
perl tes3cmd --version
```

The runtime uses modules distributed with Perl, including `Getopt::Long`,
`Storable`, `File::Temp`, and `IO::Handle`. The project does not yet declare a
minimum supported Perl version or a formal operating-system support matrix.

To build a standalone Windows executable, install PAR::Packer and run:

```sh
pp -o tes3cmd.exe tes3cmd
```

## Getting help

```sh
tes3cmd help
tes3cmd help dump
tes3cmd dump --help
tes3cmd --version
```

Options follow the command name. Common options can be abbreviated when the
abbreviation is unambiguous.

## Finding Morrowind and plugins

For commands that need an installation, tes3cmd walks upward from the current
directory until it finds a directory containing both `Data Files` and
`Morrowind.ini`. Plugin names are then resolved case-insensitively in that
`Data Files` directory.

Automation should select the location explicitly:

```sh
tes3cmd dump --morrowind-dir "/games/Morrowind" Morrowind.esm
tes3cmd dump --data-files "/games/Morrowind/Data Files" MyMod.esp
tes3cmd dump --openmw-config "$HOME/.config/openmw/openmw.cfg" MyMod.esp
```

`--morrowind-dir` requires both `Data Files` and `Morrowind.ini` beneath the
given directory. `--data-files` points directly to a data directory; its
parent is used when a command also needs `Morrowind.ini`. `--openmw-config`
reads an explicit OpenMW configuration. These three options are mutually
exclusive.

When no location is explicit, a classic Morrowind installation found by
walking upward from the current directory takes precedence over the default
OpenMW user configuration. OpenMW defaults are
`$XDG_CONFIG_HOME/openmw/openmw.cfg` (or
`$HOME/.config/openmw/openmw.cfg`) on Linux,
`$HOME/Library/Preferences/openmw/openmw.cfg` on macOS, and
`Documents/My Games/OpenMW/openmw.cfg` on Windows.

Plain `dump` and `diff` operations using explicit plugin paths work outside a
Morrowind installation without a discovery warning. Installation-dependent
features such as `--active`, load-order lookup, and master lookup need either a
classic Morrowind layout or OpenMW configuration.

Commands that load master data may create reusable caches beneath
`Morrowind/tes3cmd/cache`, or beneath `tes3cmd/cache` next to the selected
OpenMW configuration. Help, version, and location discovery alone do not create
that directory. Cache entries are tied to the cache schema, codec version, and
SHA-256 fingerprint of their source plugin. `--no-cache` bypasses cache reads
and writes without deleting existing cache files.

OpenMW `data=` directories are combined in configuration order, with later
directories overriding earlier ones. `data-local=` is always the final
override. Relative and quoted paths, the `?userconfig?`, `?userdata?`, and
`?global?` path tokens, chained `config=` directories, and `replace=data` or
`replace=content` are supported. The `?local?` token requires OpenMW's binary
location and is rejected; use an equivalent absolute path instead.
Active TES3 plugins follow `content=` order exactly instead of using file
timestamps. Native OpenMW content types such as `.omwaddon` and `.omwgame` are
ignored because tes3cmd only parses TES3 ESM/ESP files. The `active` command can
list OpenMW content but will not modify `openmw.cfg`; `--on` and `--off` are
rejected. See the [OpenMW path documentation](https://openmw.readthedocs.io/en/stable/reference/modding/paths.html)
for the underlying configuration rules.

## Common workflows

Inspect a plugin:

```sh
tes3cmd dump --type NPC_ --format "%id% %name% %faction%" Morrowind.esm
tes3cmd dump --list "My Mod.esp"
tes3cmd diff old.esp new.esp > changes.txt
```

Write a text dump to a file:

```sh
tes3cmd dump --output dump.txt "My Mod.esp"
```

Extract selected records as binary data, optionally with a new TES3 header:

```sh
tes3cmd dump --type CONT --binary --output containers.bin source.esp
tes3cmd dump --type CONT --binary --header --output containers.esp source.esp
```

Modify or delete selected records:

```sh
tes3cmd modify --type STAT --sub-match "id:" --replace "/^/PC_/" mod.esp
tes3cmd delete --type GMST mod.esp
```

Run `tes3cmd help <command>` before using a modifying command; selectors and
command-specific options are documented there.

## Output destinations

Only `dump` accepts `--output`.

- Text dumps go to standard output by default, so normal shell redirection
  remains supported. With `--output`, dump content is written only to that
  file.
- `--binary` requires `--output`; binary data is never sent to the terminal or
  mixed with status messages.
- An existing output file is preserved unless `--overwrite` is supplied.
- An output destination cannot be the input plugin, including through a hard
  link.
- `--header` is valid only with `--binary` and creates an initial TES3 header
  in the extracted plugin.

## File safety and backups

Commands that update a plugin write a unique temporary file beside the input,
finish and validate it, copy the original to a backup, and only then install
the replacement. A failed parse, write, validation, or replacement leaves the
original plugin at its original path and cleans up the command's temporary
output. A command that makes no changes does not create a backup.

By default, plugin backups are numbered beside the input, for example
`MyMod~1.esp`, `MyMod~2.esp`, and so on. `--hide-backups` stores them in the
backup directory instead; use `--backup-dir <dir>` to choose that directory.

Changes made by `active --on` or `active --off` are also transactional. A
successful change preserves the previous `Morrowind.ini` as
`Morrowind.ini.old`; a no-op does not replace that backup.

These guarantees reduce the risk of a failed write. They are not a substitute
for keeping independent backups before intentional bulk edits.

## Exit status and diagnostics

Help and version requests exit with status 0. Invalid invocations, missing
inputs, malformed plugins, failed conversions, and failures in user-supplied
Perl exit nonzero. Scripts should use the exit status, not the presence of a
warning, to decide whether a command succeeded.

Diagnostics and status messages may be written to standard error. Record text
uses standard output unless `dump --output` selects a file.

## Trusted Perl and deprecated extensions

`modify --run` and `modify --program-file` execute trusted, unsandboxed Perl
inside the tes3cmd process. That code has the same access to files, processes,
and the operating system as tes3cmd. Run only code you wrote or reviewed. A
compile-time or runtime failure aborts the transaction and identifies the
program source, plugin, and record when available.

The older filename-based command-extension mechanism still works for
compatibility, but it is deprecated and prints a warning. New automation
should use built-in commands or `modify --program-file`. The former hidden
`-run` command has been removed.

## Development

The automated suite uses Test2::Suite and IPC::Run3:

```sh
perl -c tes3cmd
prove -lr t
```

With Nix installed, the development shell supplies those dependencies:

```sh
nix develop
prove -lr t

# Or run the repository shortcut:
just test
```

## License

tes3cmd is distributed under the [MIT License](LICENSE).
