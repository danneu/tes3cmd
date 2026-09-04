use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(read_binary run_tes3cmd write_minimal_plugin);

sub make_install {
	my $installation = tempdir(CLEANUP => 1);
	my $data_files = File::Spec->catdir($installation, 'Data Files');
	make_path($data_files);
	write_minimal_plugin(File::Spec->catfile($data_files, 'active.esp'));
	my $ini = File::Spec->catfile($installation, 'Morrowind.ini');
	open(my $fh, '>', $ini) or die qq{Unable to create "$ini": $!};
	print {$fh} "[Game Files]\nGameFile0=active.esp\n"
		or die qq{Unable to write "$ini": $!};
	close($fh) or die qq{Unable to close "$ini": $!};
	return ($installation, $data_files);
}

my $workdir = tempdir(CLEANUP => 1);
my $help = run_tes3cmd($workdir, 'multipatch', '--help');
is($help->{exit}, 0, 'multipatch help succeeds');
like(
	$help->{stdout},
	qr/--merge-objects\s+unsupported;/,
	'help identifies object merging as unsupported',
);
unlike(
	$help->{stdout},
	qr/default options are assumed:\s+[^\n]*--merge-objects/s,
	'help does not include object merging in the defaults',
);

subtest 'an explicit object merge request fails without side effects' => sub {
	my ($installation, $data_files) = make_install();
	my $result = run_tes3cmd(
		$installation,
		'multipatch',
		'--morrowind-dir',
		$installation,
		'--merge-objects',
		'--no-activate',
	);

	isnt($result->{exit}, 0, 'unsupported object merge fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/--merge-objects is not supported/,
		'the unsupported feature is explained',
	);
	ok(!-e File::Spec->catfile($data_files, 'multipatch.esp'), 'no patch is created');
	ok(
		!-e File::Spec->catfile($installation, 'tes3cmd', 'cache', 'mergeable_object_data.cache'),
		'no object cache is created',
	);
};

subtest 'default multipatch enables only supported operations' => sub {
	my ($installation, $data_files) = make_install();
	my $result = run_tes3cmd(
		$installation,
		'multipatch',
		'--morrowind-dir',
		$installation,
		'--no-cache',
		'--no-activate',
	);

	is($result->{exit}, 0, 'default multipatch succeeds');
	my $patch = File::Spec->catfile($data_files, 'multipatch.esp');
	ok(-f $patch, 'default multipatch creates a patch');
	like(
		read_binary($patch),
		qr/options: cellnames,fogbug,merge_lists,summons_persist/,
		'patch metadata lists the supported defaults',
	);
	unlike(read_binary($patch), qr/merge_objects/, 'patch metadata omits object merging');
};

done_testing;
