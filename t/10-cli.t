use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(run_tes3cmd);

my $workdir = tempdir(CLEANUP => 1);

my $help = run_tes3cmd($workdir, 'help');
my $help_output = $help->{stdout} . $help->{stderr};
like($help_output, qr/^Usage: tes3cmd COMMAND/m, 'general help includes usage');
like($help_output, qr/^COMMANDS$/m, 'general help lists commands');
like($help_output, qr/^\s+dump$/m, 'general help includes dump');

my $invalid = run_tes3cmd($workdir, 'not-a-command');
isnt($invalid->{exit}, 0, 'an unknown command fails');
like(
	$invalid->{stdout} . $invalid->{stderr},
	qr/FOR MORE HELP, TYPE:/,
	'an unknown command points to help',
);

done_testing;
