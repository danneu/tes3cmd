use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(read_binary run_tes3cmd write_minimal_plugin);

sub write_text {
	my ($path, $contents) = @_;
	open(my $fh, '>', $path) or die qq{Unable to create "$path": $!};
	print {$fh} $contents or die qq{Unable to write "$path": $!};
	close($fh) or die qq{Unable to close "$path": $!};
}

sub temporary_files {
	my ($workdir) = @_;
	return [glob(File::Spec->catfile($workdir, '*.tmp.*'))];
}

subtest 'inline modify code can update selected records' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	write_minimal_plugin($plugin);

	my $result = run_tes3cmd(
		$workdir,
		'modify',
		'--type',
		'GMST',
		'--run',
		'$R->set({f=>"integer"}, 99)',
		$plugin,
	);
	is($result->{exit}, 0, 'valid inline code succeeds');

	my $dump = run_tes3cmd($workdir, 'dump', '--type', 'GMST', $plugin);
	like($dump->{stdout}, qr/Integer:99/, 'inline code modified the selected field');
};

subtest 'inline modify failures preserve the original' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	write_minimal_plugin($plugin);
	my $original = read_binary($plugin);

	my $syntax = run_tes3cmd(
		$workdir,
		'modify',
		'--type',
		'GMST',
		'--run',
		'if (',
		$plugin,
	);
	isnt($syntax->{exit}, 0, 'invalid inline Perl fails');
	like(
		$syntax->{stdout} . $syntax->{stderr},
		qr/compiling trusted Perl from --run/i,
		'the compile failure identifies inline user code',
	);
	is(read_binary($plugin), $original, 'compile failure preserves the plugin');

	my $runtime = run_tes3cmd(
		$workdir,
		'modify',
		'--type',
		'GMST',
		'--run',
		'die "inline boom\\n"',
		$plugin,
	);
	isnt($runtime->{exit}, 0, 'inline runtime exception fails');
	like(
		$runtime->{stdout} . $runtime->{stderr},
		qr/trusted Perl from --run failed.*GMST.*inline boom/is,
		'the runtime failure identifies its record and source',
	);
	is(read_binary($plugin), $original, 'runtime failure preserves the plugin');
	ok(!-e File::Spec->catfile($workdir, 'minimal~1.esp'), 'failure creates no backup');
	is(temporary_files($workdir), [], 'failure leaves no temporary output');
};

subtest 'modify program files report load and runtime failures' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	my $program = File::Spec->catfile($workdir, 'modify.pl');
	write_minimal_plugin($plugin);
	my $original = read_binary($plugin);

	write_text($program, "sub main {\n");
	my $syntax = run_tes3cmd($workdir, 'modify', '--program-file', $program, $plugin);
	isnt($syntax->{exit}, 0, 'program syntax error fails');
	like(
		$syntax->{stdout} . $syntax->{stderr},
		qr/loading trusted Perl modify program.*modify\.pl/is,
		'the load failure identifies the program file',
	);

	write_text($program, "sub main { die \"program boom\\n\" }\n1;\n");
	my $runtime = run_tes3cmd(
		$workdir,
		'modify',
		'--program-file',
		$program,
		'--type',
		'GMST',
		$plugin,
	);
	isnt($runtime->{exit}, 0, 'program runtime exception fails');
	like(
		$runtime->{stdout} . $runtime->{stderr},
		qr/trusted Perl from modify program.*modify\.pl.*failed.*GMST.*program boom/is,
		'the runtime failure identifies the program and record',
	);
	is(read_binary($plugin), $original, 'program failure preserves the plugin');
};

subtest 'modify program files can define the record callback' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
	my $program = File::Spec->catfile($workdir, 'modify.pl');
	write_minimal_plugin($plugin);
	write_text(
		$program,
		'sub main { my ($record) = @_; $record->set({f=>"integer"}, 77) }' . "\n1;\n",
	);

	my $result = run_tes3cmd(
		$workdir,
		'modify',
		'--program-file',
		$program,
		'--type',
		'GMST',
		$plugin,
	);
	is($result->{exit}, 0, 'valid modify program succeeds');
	my $dump = run_tes3cmd($workdir, 'dump', '--type', 'GMST', $plugin);
	like($dump->{stdout}, qr/Integer:77/, 'program callback modified the selected field');
};

subtest 'filename command extensions are deprecated and validated' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $extension = File::Spec->catfile($workdir, 'report.pl');
	write_text(
		$extension,
		'{ description => "test report", options => [], '
			. 'preprocess => sub { print "extension ran\\n" }, '
			. 'usage => "Usage: report" }',
	);

	my $success = run_tes3cmd($workdir, $extension);
	is($success->{exit}, 0, 'valid command extension still runs');
	like($success->{stdout}, qr/extension ran/, 'extension callback executes');
	like($success->{stderr}, qr/command extensions are deprecated/i, 'use emits a deprecation warning');

	write_text($extension, '1;');
	my $invalid = run_tes3cmd($workdir, $extension);
	isnt($invalid->{exit}, 0, 'invalid command definition fails');
	like(
		$invalid->{stdout} . $invalid->{stderr},
		qr/must return a command definition hash/i,
		'the invalid extension contract is explained',
	);

	write_text(
		$extension,
		'{ description => "broken", options => [], '
			. 'preprocess => sub { die "extension boom\\n" }, '
			. 'usage => "Usage: report" }',
	);
	my $runtime = run_tes3cmd($workdir, $extension);
	isnt($runtime->{exit}, 0, 'command extension runtime exception fails');
	like(
		$runtime->{stdout} . $runtime->{stderr},
		qr/command extension.*failed during preprocess.*extension boom/is,
		'the callback failure is attributed to the extension',
	);
};

subtest 'hidden -run command is retired with migration guidance' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $result = run_tes3cmd($workdir, '-run');
	isnt($result->{exit}, 0, '-run fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/-run.*removed.*modify --program-file/is,
		'the replacement command is identified',
	);
};

done_testing;
