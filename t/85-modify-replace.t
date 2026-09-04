use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(read_binary run_tes3cmd write_minimal_plugin);

sub write_replacement_fixture {
	my ($path) = @_;
	write_minimal_plugin($path);
	my $contents = read_binary($path);
	$contents =~ s/iTes3cmdTest/iTes3tES3TeS/
		or die 'Unable to replace the fixture record ID';
	open(my $fh, '>', $path) or die qq{Unable to update "$path": $!};
	binmode($fh, ':raw') or die qq{Unable to set binary mode on "$path": $!};
	print {$fh} $contents or die qq{Unable to update "$path": $!};
	close($fh) or die qq{Unable to close "$path": $!};
}

sub dump_gmst {
	my ($workdir, $plugin) = @_;
	return run_tes3cmd($workdir, 'dump', '--type', 'GMST', $plugin);
}

sub temporary_files {
	my ($workdir) = @_;
	return [glob(File::Spec->catfile($workdir, '*.tmp.*'))];
}

subtest '--replace changes every match without regard to case' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'global.esp');
	write_replacement_fixture($plugin);

	my $result = run_tes3cmd(
		$workdir,
		'modify',
		'--type',
		'GMST',
		'--sub-match',
		'id:',
		'--replace',
		'/tes/mod/',
		$plugin,
	);

	is($result->{exit}, 0, 'global replacement succeeds');
	my $dump = dump_gmst($workdir, $plugin);
	is($dump->{exit}, 0, 'modified plugin can be read');
	like($dump->{stdout}, qr/imod3mod3mod/i, 'all mixed-case matches are replaced');
};

subtest '--replacefirst changes only the first case-insensitive match' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'first.esp');
	write_replacement_fixture($plugin);

	my $result = run_tes3cmd(
		$workdir,
		'modify',
		'--type',
		'GMST',
		'--sub-match',
		'id:',
		'--replacefirst',
		'/tes/mod/',
		$plugin,
	);

	is($result->{exit}, 0, 'first-only replacement succeeds');
	my $dump = dump_gmst($workdir, $plugin);
	is($dump->{exit}, 0, 'modified plugin can be read');
	like($dump->{stdout}, qr/imod3tes3tes/i, 'only the first mixed-case match is replaced');
};

subtest 'invalid replacement expressions preserve the original' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'invalid.esp');
	write_replacement_fixture($plugin);
	my $original = read_binary($plugin);

	my $result = run_tes3cmd(
		$workdir,
		'modify',
		'--replace',
		'/unterminated',
		$plugin,
	);

	isnt($result->{exit}, 0, 'invalid replacement fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/invalid replacer expression/i,
		'the invalid expression is explained',
	);
	is(read_binary($plugin), $original, 'the plugin is byte-for-byte unchanged');
	ok(!-e File::Spec->catfile($workdir, 'invalid~1.esp'), 'no backup is created');
	is(temporary_files($workdir), [], 'no temporary output is left behind');
};

done_testing;
