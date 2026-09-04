use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(read_binary run_tes3cmd write_minimal_plugin);

subtest '--output is limited to dump' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $destination = File::Spec->catfile($workdir, 'ignored.txt');
	my $result = run_tes3cmd($workdir, 'active', '--output', $destination);

	isnt($result->{exit}, 0, 'an unsupported --output option fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/Unknown option: output/,
		'the unsupported option is identified',
	);
	ok(!-e $destination, 'no ignored output artifact is created');
};

subtest 'text dump writes only to the requested destination' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	my $destination = File::Spec->catfile($workdir, 'dump.txt');
	write_minimal_plugin($plugin);

	my $result = run_tes3cmd(
		$workdir,
		'dump',
		'--output',
		$destination,
		'--type',
		'GMST',
		$plugin,
	);

	is($result->{exit}, 0, 'text dump succeeds');
	is($result->{stdout}, '', 'dump content is not also written to stdout');
	like(read_binary($destination), qr/Record: GMST "ites3cmdtest"/, 'destination contains the dump');
};

subtest 'binary dump requires and uses a file destination' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	my $destination = File::Spec->catfile($workdir, 'record.bin');
	my $plugin_destination = File::Spec->catfile($workdir, 'extract.esp');
	write_minimal_plugin($plugin);

	my $missing = run_tes3cmd($workdir, 'dump', '--binary', $plugin);
	isnt($missing->{exit}, 0, 'binary dump without --output fails');
	like(
		$missing->{stdout} . $missing->{stderr},
		qr/--binary requires --output/,
		'the required destination is explained',
	);
	unlike($missing->{stdout}, qr/Record: GMST/, 'binary mode does not fall back to text');

	my $result = run_tes3cmd(
		$workdir,
		'dump',
		'--binary',
		'--output',
		$destination,
		'--type',
		'GMST',
		$plugin,
	);

	is($result->{exit}, 0, 'binary dump succeeds with a destination');
	is($result->{stdout}, '', 'no status or binary data is written to stdout');
	is(substr(read_binary($destination), 0, 4), 'GMST', 'destination contains binary records');
	like($result->{stderr}, qr/Raw records saved in/, 'status is written separately');

	my $with_header = run_tes3cmd(
		$workdir,
		'dump',
		'--binary',
		'--header',
		'--output',
		$plugin_destination,
		'--type',
		'GMST',
		$plugin,
	);
	is($with_header->{exit}, 0, 'binary dump with a generated header succeeds');
	is(substr(read_binary($plugin_destination), 0, 4), 'TES3', 'header option prefixes a TES3 record');
};

subtest 'existing destinations require --overwrite' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	my $destination = File::Spec->catfile($workdir, 'dump.txt');
	write_minimal_plugin($plugin);

	open(my $existing, '>', $destination) or die "Unable to create destination: $!";
	print {$existing} 'keep me' or die "Unable to write destination: $!";
	close($existing) or die "Unable to close destination: $!";

	my $rejected = run_tes3cmd($workdir, 'dump', '--output', $destination, $plugin);
	isnt($rejected->{exit}, 0, 'existing destination is rejected by default');
	like(
		$rejected->{stdout} . $rejected->{stderr},
		qr/already exists.*--overwrite/s,
		'the overwrite requirement is explained',
	);
	is(read_binary($destination), 'keep me', 'existing destination is preserved');

	my $overwritten = run_tes3cmd(
		$workdir,
		'dump',
		'--overwrite',
		'--output',
		$destination,
		'--type',
		'GMST',
		$plugin,
	);
	is($overwritten->{exit}, 0, 'explicit overwrite succeeds');
	like(read_binary($destination), qr/Record: GMST/, 'existing destination is replaced');
};

subtest 'output cannot overwrite an input plugin' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	write_minimal_plugin($plugin);
	my $original = read_binary($plugin);

	my $result = run_tes3cmd(
		$workdir,
		'dump',
		'--overwrite',
		'--output',
		$plugin,
		$plugin,
	);

	isnt($result->{exit}, 0, 'input and output cannot be the same file');
	like(
		$result->{stdout} . $result->{stderr},
		qr/output destination.*input plugin/i,
		'the destructive conflict is identified',
	);
	is(read_binary($plugin), $original, 'the input plugin is preserved');
};

subtest 'output cannot overwrite a hard link to an input plugin' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	my $destination = File::Spec->catfile($workdir, 'linked-output');
	write_minimal_plugin($plugin);
	my $original = read_binary($plugin);
	link($plugin, $destination) or skip_all "Hard links are unavailable: $!";

	my $result = run_tes3cmd(
		$workdir,
		'dump',
		'--overwrite',
		'--output',
		$destination,
		$plugin,
	);

	isnt($result->{exit}, 0, 'an alias of the input is rejected');
	is(read_binary($plugin), $original, 'the input bytes are preserved');
};

subtest 'stdout remains the default text destination' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	write_minimal_plugin($plugin);

	my $result = run_tes3cmd($workdir, 'dump', '--type', 'GMST', $plugin);

	is($result->{exit}, 0, 'ordinary text dump succeeds');
	like($result->{stdout}, qr/Record: GMST/, 'text remains available for shell redirection');
};

done_testing;
