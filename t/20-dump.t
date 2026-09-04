use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(run_tes3cmd write_minimal_plugin);

my $workdir = tempdir(CLEANUP => 1);
my $plugin = File::Spec->catfile($workdir, 'minimal.esp');
write_minimal_plugin($plugin);

my $result = run_tes3cmd($workdir, 'dump', '--type', 'GMST', $plugin);

is($result->{exit}, 0, 'dump succeeds for a minimal plugin');
like(
	$result->{stdout},
	qr/Record: GMST "ites3cmdtest"/,
	'dump identifies the fixture record',
);
like($result->{stdout}, qr/Integer:42/, 'dump decodes the fixture value');

done_testing;
