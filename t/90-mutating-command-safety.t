use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(
	read_binary
	run_tes3cmd
	run_tes3cmd_with_env
	write_minimal_plugin
);

sub write_binary {
	my ($path, $contents) = @_;
	open(my $fh, '>', $path) or die qq{Unable to create "$path": $!};
	binmode($fh, ':raw') or die qq{Unable to set binary mode on "$path": $!};
	print {$fh} $contents or die qq{Unable to write "$path": $!};
	close($fh) or die qq{Unable to close "$path": $!};
}

sub temporary_files {
	my ($directory) = @_;
	opendir(my $dir, $directory) or die qq{Unable to inspect "$directory": $!};
	my @files = map { File::Spec->catfile($directory, $_) }
		grep { /\.tmp\./ } readdir($dir);
	closedir($dir) or die qq{Unable to close "$directory": $!};
	return [sort @files];
}

sub write_master {
	my ($path) = @_;
	write_minimal_plugin($path);
	my $contents = read_binary($path);
	substr($contents, 28, 1, "\001");
	write_binary($path, $contents);
}

sub make_install {
	my $installation = tempdir(CLEANUP => 1);
	my $data_files = File::Spec->catdir($installation, 'Data Files');
	make_path($data_files);
	my $plugin = File::Spec->catfile($data_files, 'active.esp');
	write_minimal_plugin($plugin);
	write_binary(
		File::Spec->catfile($installation, 'Morrowind.ini'),
		"[Game Files]\nGameFile0=active.esp\n",
	);
	return ($installation, $data_files, $plugin);
}

subtest 'header updates are transactional and no-ops make no backup' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'header.esp');
	my $backup = File::Spec->catfile($workdir, 'header~1.esp');
	write_minimal_plugin($plugin);
	my $original = read_binary($plugin);

	my $updated = run_tes3cmd($workdir, 'header', '--author', 'new author', $plugin);
	is($updated->{exit}, 0, 'header update succeeds');
	is(read_binary($backup), $original, 'header backup contains the original bytes');
	is(unpack('Z32', substr(read_binary($plugin), 32, 32)), 'new author', 'author is updated');
	is(temporary_files($workdir), [], 'successful header update leaves no temporary files');

	unlink($backup) or die qq{Unable to remove test backup "$backup": $!};
	my $after_update = read_binary($plugin);
	my $noop = run_tes3cmd($workdir, 'header', '--author', 'new author', $plugin);
	is($noop->{exit}, 0, 'identical header update succeeds');
	is(read_binary($plugin), $after_update, 'identical header update preserves every byte');
	ok(!-e $backup, 'identical header update creates no backup');
};

subtest 'header failures preserve the original and clean up' => sub {
	for my $case (
		['write', { TES3CMD_TEST_FAIL_PLUGIN_WRITE => 1 }, qr/writing temporary plugin output/i],
		['replacement', { TES3CMD_TEST_FAIL_REPLACE => 1 }, qr/installing replacement/i],
	) {
		my ($name, $environment, $message) = @{$case};
		my $workdir = tempdir(CLEANUP => 1);
		my $plugin = File::Spec->catfile($workdir, "$name.esp");
		write_minimal_plugin($plugin);
		my $original = read_binary($plugin);
		my $result = run_tes3cmd_with_env(
			$workdir,
			$environment,
			'header',
			'--description',
			'changed',
			$plugin,
		);

		isnt($result->{exit}, 0, "$name failure fails the command");
		like($result->{stdout} . $result->{stderr}, $message, "$name failure is reported");
		is(read_binary($plugin), $original, "$name failure preserves the original");
		is(temporary_files($workdir), [], "$name failure cleans up temporary files");
	}

	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'malformed.esp');
	write_minimal_plugin($plugin);
	write_binary($plugin, read_binary($plugin) . 'BROKEN');
	my $original = read_binary($plugin);
	my $result = run_tes3cmd($workdir, 'header', '--author', 'changed', $plugin);
	isnt($result->{exit}, 0, 'malformed plugin fails header update');
	is(read_binary($plugin), $original, 'malformed plugin is untouched');
	ok(!-e File::Spec->catfile($workdir, 'malformed~1.esp'), 'malformed plugin is not backed up');
	is(temporary_files($workdir), [], 'malformed header update cleans up');
};

subtest 'esp and esm conversion installs only completed validated output' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'convert.esp');
	my $master = File::Spec->catfile($workdir, 'convert.esm');
	write_minimal_plugin($plugin);
	my $original = read_binary($plugin);

	my $result = run_tes3cmd($workdir, 'esm', $plugin);
	is($result->{exit}, 0, 'plugin-to-master conversion succeeds');
	is(read_binary($plugin), $original, 'conversion leaves its input untouched');
	is(substr(read_binary($master), 28, 1), "\001", 'converted output has the master flag');
	is(temporary_files($workdir), [], 'conversion leaves no temporary files');

	write_binary($master, 'existing destination');
	my $existing = run_tes3cmd($workdir, 'esm', $plugin);
	isnt($existing->{exit}, 0, 'existing destination is rejected without --overwrite');
	is(read_binary($master), 'existing destination', 'rejected destination is untouched');

	my $failed = run_tes3cmd_with_env(
		$workdir,
		{ TES3CMD_TEST_FAIL_REPLACE => 1 },
		'esm',
		'--overwrite',
		$plugin,
	);
	isnt($failed->{exit}, 0, 'conversion replacement failure fails the command');
	is(read_binary($master), 'existing destination', 'replacement failure restores the prior output');
	is(temporary_files($workdir), [], 'failed conversion leaves no temporary files');
};

subtest 'conversion write failure never publishes partial output' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $master = File::Spec->catfile($workdir, 'convert.esm');
	my $plugin = File::Spec->catfile($workdir, 'convert.esp');
	write_master($master);

	my $result = run_tes3cmd_with_env(
		$workdir,
		{ TES3CMD_TEST_FAIL_PLUGIN_WRITE => 1 },
		'esp',
		$master,
	);
	isnt($result->{exit}, 0, 'conversion write failure fails the command');
	ok(!-e $plugin, 'conversion write failure creates no final output');
	is(temporary_files($workdir), [], 'conversion write failure cleans up');
};

subtest 'prefixed plugin output is protected and transaction-safe' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'codec.esp');
	my $output = File::Spec->catfile($workdir, 'test_codec.esp');
	write_minimal_plugin($plugin);
	write_binary($output, 'existing output');

	my $existing = run_tes3cmd($workdir, '-testcodec', $plugin);
	isnt($existing->{exit}, 0, 'prefixed output rejects accidental overwrite');
	is(read_binary($output), 'existing output', 'existing prefixed output is untouched');

	my $failed = run_tes3cmd_with_env(
		$workdir,
		{ TES3CMD_TEST_FAIL_REPLACE => 1 },
		'-testcodec',
		'--overwrite',
		$plugin,
	);
	isnt($failed->{exit}, 0, 'prefixed output replacement failure fails the command');
	is(read_binary($output), 'existing output', 'prefixed output replacement failure restores the destination');
	is(temporary_files($workdir), [], 'failed prefixed output cleans up temporary files');
};

subtest 'recover uses the shared transactional replacement path' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'recover.esp');
	write_minimal_plugin($plugin);
	my $valid = read_binary($plugin);
	my $header_length = 16 + unpack('V', substr($valid, 4, 4));
	my $damaged = substr($valid, 0, $header_length) . 'BROKEN' . substr($valid, $header_length);
	write_binary($plugin, $damaged);

	my $result = run_tes3cmd($workdir, 'recover', $plugin);
	is($result->{exit}, 0, 'recover succeeds when a later complete record can be found');
	is(read_binary(File::Spec->catfile($workdir, 'recover~1.esp')), $damaged, 'recover backs up damaged input');
	is(read_binary($plugin), $valid, 'recover installs the validated recovered plugin');
	is(temporary_files($workdir), [], 'recover cleans up temporary files');

	write_binary($plugin, $damaged);
	my $failed = run_tes3cmd_with_env(
		$workdir,
		{ TES3CMD_TEST_FAIL_REPLACE => 1 },
		'recover',
		$plugin,
	);
	isnt($failed->{exit}, 0, 'recover replacement failure fails the command');
	is(read_binary($plugin), $damaged, 'recover replacement failure preserves damaged input');
	is(temporary_files($workdir), [], 'failed recover cleans up temporary files');

	my $write_failed = run_tes3cmd_with_env(
		$workdir,
		{ TES3CMD_TEST_FAIL_PLUGIN_WRITE => 1 },
		'recover',
		$plugin,
	);
	isnt($write_failed->{exit}, 0, 'recover write failure fails the command');
	is(read_binary($plugin), $damaged, 'recover write failure preserves damaged input');
	is(temporary_files($workdir), [], 'recover write failure cleans up temporary files');
};

subtest 'multipatch publishes atomically and requires overwrite permission' => sub {
	my ($installation, $data_files) = make_install();
	my $patch = File::Spec->catfile($data_files, 'multipatch.esp');
	my @arguments = (
		'multipatch',
		'--morrowind-dir',
		$installation,
		'--merge-lists',
		'--no-cache',
		'--no-activate',
	);

	my $created = run_tes3cmd($installation, @arguments);
	is($created->{exit}, 0, 'multipatch succeeds');
	ok(-f $patch, 'multipatch output is published');
	is(temporary_files($data_files), [], 'multipatch leaves no temporary files');
	my $original_patch = read_binary($patch);

	my $existing = run_tes3cmd($installation, @arguments);
	isnt($existing->{exit}, 0, 'existing multipatch is rejected without --overwrite');
	is(read_binary($patch), $original_patch, 'rejected multipatch remains untouched');

	my $failed = run_tes3cmd_with_env(
		$installation,
		{ TES3CMD_TEST_FAIL_REPLACE => 1 },
		@arguments,
		'--overwrite',
	);
	isnt($failed->{exit}, 0, 'multipatch replacement failure fails the command');
	is(read_binary($patch), $original_patch, 'multipatch replacement failure preserves prior output');
	is(temporary_files($data_files), [], 'failed multipatch cleans up temporary files');

	my $write_failed = run_tes3cmd_with_env(
		$installation,
		{ TES3CMD_TEST_FAIL_PLUGIN_WRITE => 1 },
		@arguments,
		'--overwrite',
	);
	isnt($write_failed->{exit}, 0, 'multipatch write failure fails the command');
	is(read_binary($patch), $original_patch, 'multipatch write failure preserves prior output');
	is(temporary_files($data_files), [], 'multipatch write failure cleans up temporary files');
};

subtest 'fixit resolves active plugins through Data Files without leaking patch header options' => sub {
	my ($installation, $data_files, $plugin) = make_install();
	my $original = read_binary($plugin);
	my $result = run_tes3cmd(
		$installation,
		'fixit',
		'--morrowind-dir',
		$installation,
	);

	is($result->{exit}, 0, 'fixit succeeds from the installation root');
	is(read_binary($plugin), $original, 'fixit leaves an already-clean plugin byte-for-byte unchanged');
	ok(!-e File::Spec->catfile($data_files, 'active~1.esp'), 'fixit creates no backup for the no-op plugin');
	is(
		unpack('Z32', substr(read_binary($plugin), 32, 32)),
		'tes3cmd tests',
		'multipatch author settings do not leak into synchronized plugins',
	);
	ok(-f File::Spec->catfile($data_files, 'multipatch.esp'), 'fixit publishes its generated patch');
};

done_testing;
