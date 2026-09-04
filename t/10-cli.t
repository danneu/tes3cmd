use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(run_tes3cmd write_minimal_plugin);

my $workdir = tempdir(CLEANUP => 1);

my $help = run_tes3cmd($workdir, 'help');
my $help_output = $help->{stdout} . $help->{stderr};
is($help->{exit}, 0, 'general help succeeds');
like($help_output, qr/^Usage: tes3cmd COMMAND/m, 'general help includes usage');
like($help_output, qr/^COMMANDS$/m, 'general help lists commands');
like($help_output, qr/^\s+dump$/m, 'general help includes dump');
unlike($help_output, qr/Can't find "Data Files"/, 'help does not perform discovery');

my $long_help = run_tes3cmd($workdir, '--help');
is($long_help->{exit}, 0, '--help succeeds');
like($long_help->{stdout}, qr/^Usage: tes3cmd COMMAND/m, '--help prints general help');
is($long_help->{stderr}, '', '--help does not warn');

my $old_help = run_tes3cmd($workdir, '-help');
is($old_help->{exit}, 0, 'legacy -help remains supported');

my $command_help = run_tes3cmd($workdir, 'dump', '--help');
is($command_help->{exit}, 0, 'command --help succeeds');
like($command_help->{stdout}, qr/^Usage: tes3cmd dump/m, 'command --help prints command help');
is($command_help->{stderr}, '', 'command --help does not warn');

my $legacy_command_help = run_tes3cmd($workdir, 'help', 'dump');
is($legacy_command_help->{exit}, 0, 'help command succeeds');
like($legacy_command_help->{stdout}, qr/^Usage: tes3cmd dump/m, 'help command remains supported');

my $version = run_tes3cmd($workdir, '--version');
is($version->{exit}, 0, '--version succeeds');
like($version->{stdout}, qr/^tes3cmd \S+\n\z/, '--version prints the program version');
is($version->{stderr}, '', '--version does not warn');

my $invalid = run_tes3cmd($workdir, 'not-a-command');
isnt($invalid->{exit}, 0, 'an unknown command fails');
like(
	$invalid->{stdout} . $invalid->{stderr},
	qr/FOR MORE HELP, TYPE:/,
	'an unknown command points to help',
);
unlike(
	$invalid->{stdout} . $invalid->{stderr},
	qr/Can't find "Data Files"/,
	'an unknown command does not perform discovery',
);

my $missing_plugin = run_tes3cmd($workdir, 'dump', 'missing.esp');
isnt($missing_plugin->{exit}, 0, 'a processing failure returns nonzero');

my $bad_master = File::Spec->catfile($workdir, 'bad.esm');
open(my $bad_fh, '>', $bad_master) or die qq{Unable to create "$bad_master": $!};
print {$bad_fh} 'not a plugin' or die qq{Unable to write "$bad_master": $!};
close($bad_fh) or die qq{Unable to close "$bad_master": $!};
my $failed_conversion = run_tes3cmd($workdir, 'esp', $bad_master);
isnt($failed_conversion->{exit}, 0, 'a reported conversion failure returns nonzero');
ok(!-e File::Spec->catfile($workdir, 'bad.esp'), 'failed conversion removes its output');

my $no_command = run_tes3cmd($workdir);
isnt($no_command->{exit}, 0, 'a missing command returns nonzero');

my $standalone = File::Spec->catfile($workdir, 'standalone.esp');
write_minimal_plugin($standalone);
my $diff = run_tes3cmd($workdir, 'diff', $standalone, $standalone);
is($diff->{exit}, 0, 'standalone diff succeeds');
unlike($diff->{stderr}, qr/Can't find "Data Files"/, 'standalone diff needs no installation warning');

subtest 'explicit Morrowind and Data Files locations resolve plugins' => sub {
	my $installation = File::Spec->catdir($workdir, 'Morrowind');
	my $data_files = File::Spec->catdir($installation, 'Data Files');
	my $plugin = File::Spec->catfile($data_files, 'minimal.esp');
	make_path($data_files);
	write_minimal_plugin($plugin);
	my $ini = File::Spec->catfile($installation, 'Morrowind.ini');
	open(my $ini_fh, '>', $ini) or die qq{Unable to create "$ini": $!};
	print {$ini_fh} "[Game Files]\nGameFile0=minimal.esp\n"
		or die qq{Unable to write "$ini": $!};
	close($ini_fh) or die qq{Unable to close "$ini": $!};

	my $by_data = run_tes3cmd(
		$workdir,
		'dump',
		'--data-files',
		$data_files,
		'--type',
		'GMST',
		'minimal.esp',
	);
	is($by_data->{exit}, 0, '--data-files resolves a plugin name');
	like($by_data->{stdout}, qr/Record: GMST/, 'plugin from Data Files is dumped');

	my $by_installation = run_tes3cmd(
		$workdir,
		'dump',
		'--morrowind-dir',
		$installation,
		'--type',
		'GMST',
		'minimal.esp',
	);
	is($by_installation->{exit}, 0, '--morrowind-dir resolves a plugin name');
	like($by_installation->{stdout}, qr/Record: GMST/, 'plugin from the installation is dumped');

	my $active = run_tes3cmd(
		$workdir,
		'dump',
		'--active',
		'--morrowind-dir',
		$installation,
		'--type',
		'GMST',
	);
	is($active->{exit}, 0, 'explicit installation supports --active from another directory');
	like($active->{stdout}, qr/Record: GMST/, 'active plugin path is resolved through Data Files');

	ok(!-e File::Spec->catdir($installation, 'tes3cmd'), 'read-only discovery creates no cache directory');

	my $conflict = run_tes3cmd(
		$workdir,
		'dump',
		'--data-files',
		$data_files,
		'--morrowind-dir',
		$installation,
		$plugin,
	);
	isnt($conflict->{exit}, 0, 'conflicting explicit locations fail');
	like(
		$conflict->{stdout} . $conflict->{stderr},
		qr/cannot be used together/,
		'the location conflict is explained',
	);
};

done_testing;
