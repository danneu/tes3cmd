use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(run_command tes3cmd_path);

my $workdir = tempdir(CLEANUP => 1);
my $result = run_command($workdir, $^X, '-c', tes3cmd_path());

is($result->{exit}, 0, 'tes3cmd compiles');
like($result->{stderr}, qr/syntax OK/, 'Perl reports valid syntax');

done_testing;
