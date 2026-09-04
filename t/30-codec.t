use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(read_binary run_tes3cmd write_minimal_plugin);

my $workdir = tempdir(CLEANUP => 1);
my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
my $round_trip = File::Spec->catfile($workdir, 'test_minimal.esp');
write_minimal_plugin($plugin);

my $result = run_tes3cmd($workdir, '-testcodec', $plugin);

is($result->{exit}, 0, 'codec check succeeds for a minimal plugin');
unlike(
	$result->{stdout} . $result->{stderr},
	qr/CODEC FAILURE/,
	'codec check reports no mismatch',
);
ok(-f $round_trip, 'codec check writes a round-trip plugin');
is(read_binary($round_trip), read_binary($plugin), 'codec round trip preserves every byte');
is([glob(File::Spec->catfile($workdir, '*.tmp.*'))], [], 'codec check cleans its temporary file');
ok(!-f File::Spec->catfile($workdir, 'minimal~1.esp'), 'named output does not back up the input');

done_testing;
