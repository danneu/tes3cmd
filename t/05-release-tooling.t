use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(run_command);

my $root = dirname(dirname(abs_path(__FILE__)));
my $current_version = File::Spec->catfile($root, 'scripts', 'current-version.sh');
my $next_version = File::Spec->catfile($root, 'scripts', 'next-version.sh');
my $set_version = File::Spec->catfile($root, 'scripts', 'set-version.sh');

sub command_stdout {
	my ($cwd, @command) = @_;
	my $result = run_command($cwd, @command);
	is($result->{exit}, 0, "@command succeeds") or diag($result->{stderr});
	return $result->{stdout};
}

subtest 'stable release tags determine the current version' => sub {
	my $repo = tempdir(CLEANUP => 1);
	command_stdout($repo, 'git', 'init', '--quiet');
	command_stdout($repo, 'git', '-c', 'user.name=tes3cmd tests',
		'-c', 'user.email=tests@example.invalid', 'commit', '--quiet',
		'--allow-empty', '-m', 'initial');

	is(command_stdout($repo, 'bash', $current_version), "0.39.0\n",
		'the prerelease line starts from the 0.39.0 stable baseline');
	command_stdout($repo, 'git', 'tag', 'v0.40-pre-release-2');
	is(command_stdout($repo, 'bash', $current_version), "0.39.0\n",
		'prerelease tags do not count as stable releases');
	command_stdout($repo, 'git', 'tag', 'v0.40.0');
	command_stdout($repo, 'git', 'tag', 'v0.41.2');
	command_stdout($repo, 'git', 'tag', 'not-a-release');
	is(command_stdout($repo, 'bash', $current_version), "0.41.2\n",
		'the highest stable SemVer tag wins');
};

subtest 'release bumping follows SemVer' => sub {
	for my $case (
		['patch', '0.39.1'],
		['minor', '0.40.0'],
		['major', '1.0.0'],
	) {
		my ($bump, $expected) = @{$case};
		is(command_stdout($root, 'bash', $next_version, '0.39.0', $bump),
			"$expected\n", "$bump bump produces $expected");
	}

	my $invalid = run_command($root, 'bash', $next_version, '0.39.0', 'banana');
	isnt($invalid->{exit}, 0, 'an unknown bump fails');
};

subtest 'program and Nix package versions stay synchronized' => sub {
	open(my $program_fh, '<', File::Spec->catfile($root, 'tes3cmd'))
		or die "Unable to read tes3cmd: $!";
	my $program = do { local $/; <$program_fh> };
	close($program_fh) or die "Unable to close tes3cmd: $!";

	open(my $flake_fh, '<', File::Spec->catfile($root, 'flake.nix'))
		or die "Unable to read flake.nix: $!";
	my $flake = do { local $/; <$flake_fh> };
	close($flake_fh) or die "Unable to close flake.nix: $!";

	my ($program_version) = $program =~ /\$::VERSION = "([^"]+)"/;
	my ($flake_version) = $flake =~ /^\s*version = "([^"]+)";/m;
	is($flake_version, $program_version, 'release metadata uses one version');
};

subtest 'release version updates are synchronized' => sub {
	my $copy_root = tempdir(CLEANUP => 1);
	copy(File::Spec->catfile($root, 'tes3cmd'),
		File::Spec->catfile($copy_root, 'tes3cmd')) or die "Unable to copy tes3cmd: $!";
	copy(File::Spec->catfile($root, 'flake.nix'),
		File::Spec->catfile($copy_root, 'flake.nix')) or die "Unable to copy flake.nix: $!";

	command_stdout($root, 'bash', $set_version, '1.2.3', $copy_root);
	my $program = command_stdout($root, $^X,
		File::Spec->catfile($copy_root, 'tes3cmd'), '--version');
	is($program, "tes3cmd 1.2.3\n", 'the program reports the release version');

	open(my $flake_fh, '<', File::Spec->catfile($copy_root, 'flake.nix'))
		or die "Unable to read copied flake.nix: $!";
	my $flake = do { local $/; <$flake_fh> };
	close($flake_fh) or die "Unable to close copied flake.nix: $!";
	like($flake, qr/^\s*version = "1\.2\.3";/m,
		'the Nix package uses the release version');

	my $invalid = run_command($root, 'bash', $set_version, 'not-a-version', $copy_root);
	isnt($invalid->{exit}, 0, 'an invalid release version fails');
};

done_testing;
