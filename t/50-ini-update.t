use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(read_binary run_tes3cmd_with_env);

sub write_binary {
	my ($path, $contents) = @_;
	open(my $fh, '>', $path) or die qq{Unable to create "$path": $!};
	binmode($fh, ':raw') or die qq{Unable to set binary mode on "$path": $!};
	print {$fh} $contents or die qq{Unable to write "$path": $!};
	close($fh) or die qq{Unable to close "$path": $!};
}

sub make_install {
	my ($contents) = @_;
	my $workdir = tempdir(CLEANUP => 1);
	make_path(File::Spec->catdir($workdir, 'Data Files'));
	my $ini = File::Spec->catfile($workdir, 'Morrowind.ini');
	write_binary($ini, $contents);
	return ($workdir, $ini);
}

sub run_active {
	my ($workdir, $environment, @arguments) = @_;
	return run_tes3cmd_with_env(
		$workdir,
		{ PWD => $workdir, %{$environment} },
		'active',
		@arguments,
	);
}

sub temporary_files {
	my ($workdir) = @_;
	return [glob(File::Spec->catfile($workdir, 'Morrowind.ini.tmp.*'))];
}

my $crlf_ini = join(
	'',
	"[General]\r\n",
	"Setting=keep\r\n",
	"[game files]\r\n",
	"; keep this comment\r\n",
	"GameFile7=Old.esp\r\n",
	"Custom=keep\r\n",
	"[Other]\r\n",
	"Value=untouched\r\n",
);

subtest 'activation preserves unrelated content and replaces the old backup' => sub {
	my ($workdir, $ini) = make_install($crlf_ini);
	my $old = "$ini.old";
	my $legacy_temp = "$ini.tmp";
	write_binary($old, 'stale backup');
	write_binary($legacy_temp, 'do not touch');

	my $result = run_active($workdir, {}, '--on', 'New.esp');

	is($result->{exit}, 0, 'activation succeeds');
	like($result->{stdout}, qr/ACTIVATED: New\.esp/, 'activation is reported');
	is(read_binary($old), $crlf_ini, 'the fixed backup contains the original bytes');
	is(
		read_binary($ini),
		join(
			'',
			"[General]\r\n",
			"Setting=keep\r\n",
			"[game files]\r\n",
			"; keep this comment\r\n",
			"GameFile0=New.esp\r\n",
			"GameFile1=Old.esp\r\n",
			"Custom=keep\r\n",
			"[Other]\r\n",
			"Value=untouched\r\n",
		),
		'only GameFile entries change and CRLF endings are preserved',
	);
	is(read_binary($legacy_temp), 'do not touch', 'the legacy temp path is untouched');
	is(temporary_files($workdir), [], 'no unique temporary file remains');
};

subtest 'already-active plugin is a byte-for-byte no-op' => sub {
	my ($workdir, $ini) = make_install($crlf_ini);
	my $result = run_active($workdir, {}, '--on', 'Old.esp');

	is($result->{exit}, 0, 'no-op activation succeeds');
	unlike($result->{stdout}, qr/ACTIVATED:/, 'no activation is reported');
	is(read_binary($ini), $crlf_ini, 'the INI is unchanged');
	ok(!-e "$ini.old", 'no backup is created');
	is(temporary_files($workdir), [], 'no temporary file is created');
};

subtest 'LF endings and an unterminated final line are preserved' => sub {
	my $contents = "[Game Files]\nGameFile4=Old.esp\n[Other]\nTail=keep";
	my ($workdir, $ini) = make_install($contents);

	my $result = run_active($workdir, {}, '--off', 'Old.esp');

	is($result->{exit}, 0, 'deactivation succeeds');
	is(
		read_binary($ini),
		"[Game Files]\n[Other]\nTail=keep",
		'LF endings and the final line are unchanged',
	);
	is(read_binary("$ini.old"), $contents, 'the LF input is backed up byte-for-byte');
};

subtest 'write failure preserves the original and cleans up' => sub {
	my ($workdir, $ini) = make_install($crlf_ini);
	my $result = run_active(
		$workdir,
		{ TES3CMD_TEST_FAIL_INI_WRITE => 1 },
		'--on',
		'New.esp',
	);

	isnt($result->{exit}, 0, 'write failure fails the command');
	like(
		$result->{stdout} . $result->{stderr},
		qr/writing temporary Morrowind\.ini/i,
		'the write failure is reported',
	);
	is(read_binary($ini), $crlf_ini, 'the original is untouched');
	ok(!-e "$ini.old", 'no backup is installed');
	is(temporary_files($workdir), [], 'the temporary output is removed');
};

subtest 'replacement failure restores the original' => sub {
	my ($workdir, $ini) = make_install($crlf_ini);
	my $result = run_active(
		$workdir,
		{ TES3CMD_TEST_FAIL_REPLACE => 1 },
		'--on',
		'New.esp',
	);

	isnt($result->{exit}, 0, 'replacement failure fails the command');
	like(
		$result->{stdout} . $result->{stderr},
		qr/installing replacement/i,
		'the replacement failure is reported',
	);
	is(read_binary($ini), $crlf_ini, 'the original remains at its original path');
	is(read_binary("$ini.old"), $crlf_ini, 'the backup also contains the original');
	is(temporary_files($workdir), [], 'replacement and rollback temporaries are removed');
};

done_testing;
