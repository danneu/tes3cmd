use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(
	read_binary
	run_tes3cmd
	run_tes3cmd_with_env
	write_minimal_plugin
);

sub temporary_files {
	my ($workdir) = @_;
	return [glob(File::Spec->catfile($workdir, '*.tmp.*'))];
}

subtest 'successful update replaces the plugin and preserves a backup' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	my $backup = File::Spec->catfile($workdir, 'minimal~1.esp');
	write_minimal_plugin($plugin);
	my $original = read_binary($plugin);

	my $result = run_tes3cmd($workdir, 'delete', '--type', 'GMST', $plugin);

	is($result->{exit}, 0, 'delete succeeds');
	ok(-f $backup, 'a numbered backup is created');
	is(read_binary($backup), $original, 'the backup contains the original bytes');
	isnt(read_binary($plugin), $original, 'the plugin is replaced');
	is(temporary_files($workdir), [], 'no temporary file remains');

	my $dump = run_tes3cmd($workdir, 'dump', '--type', 'GMST', $plugin);
	unlike($dump->{stdout}, qr/Record: GMST/, 'the selected record was deleted');
};

subtest 'no-op leaves the plugin and an existing legacy temp file alone' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	my $legacy_temp = "$plugin.tmp";
	write_minimal_plugin($plugin);
	my $original = read_binary($plugin);

	open(my $sentinel, '>', $legacy_temp) or die "Unable to create sentinel: $!";
	print {$sentinel} 'do not touch' or die "Unable to write sentinel: $!";
	close($sentinel) or die "Unable to close sentinel: $!";

	my $result = run_tes3cmd($workdir, 'delete', '--type', 'STAT', $plugin);

	is($result->{exit}, 0, 'no-op command succeeds');
	like($result->{stdout}, qr/was not modified/, 'no-op is reported');
	is(read_binary($plugin), $original, 'the plugin is byte-for-byte unchanged');
	is(read_binary($legacy_temp), 'do not touch', 'the legacy temp path is untouched');
	ok(!-f File::Spec->catfile($workdir, 'minimal~1.esp'), 'no backup is created');
	is(temporary_files($workdir), [], 'no unique temporary file remains');
};

subtest 'malformed input leaves the original in place and cleans up' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'broken.esp');
	write_minimal_plugin($plugin);
	open(my $fh, '>>', $plugin) or die "Unable to open malformed fixture: $!";
	binmode($fh, ':raw') or die "Unable to set binary mode: $!";
	print {$fh} 'BROKEN' or die "Unable to corrupt fixture: $!";
	close($fh) or die "Unable to close malformed fixture: $!";
	my $original = read_binary($plugin);

	my $result = run_tes3cmd($workdir, 'delete', '--type', 'GMST', $plugin);

	isnt($result->{exit}, 0, 'malformed input fails the command');
	like(
		$result->{stdout} . $result->{stderr},
		qr/Read Error.*header/s,
		'the malformed record is reported',
	);
	is(read_binary($plugin), $original, 'the malformed original is untouched');
	ok(!-f File::Spec->catfile($workdir, 'broken~1.esp'), 'no backup is created');
	is(temporary_files($workdir), [], 'the temporary output is removed');
};

subtest 'replacement failure restores the original' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	write_minimal_plugin($plugin);
	my $original = read_binary($plugin);

	my $result = run_tes3cmd_with_env(
		$workdir,
		{ TES3CMD_TEST_FAIL_REPLACE => 1 },
		'delete',
		'--type',
		'GMST',
		$plugin,
	);

	isnt($result->{exit}, 0, 'replacement failure fails the command');
	like(
		$result->{stdout} . $result->{stderr},
		qr/installing replacement/i,
		'the replacement failure is reported',
	);
	is(read_binary($plugin), $original, 'the original remains at its original path');
	is(temporary_files($workdir), [], 'replacement and rollback temporaries are removed');
};

done_testing;
