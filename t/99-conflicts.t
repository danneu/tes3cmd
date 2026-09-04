use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(read_binary run_tes3cmd write_minimal_plugin);

sub subrecord_bytes {
	my ($type, $payload) = @_;
	return pack('a4V', $type, length($payload)) . $payload;
}

sub record_bytes {
	my ($type, @subrecords) = @_;
	my $payload = join('', @subrecords);
	return pack('a4VVV', $type, length($payload), 0, 0) . $payload;
}

sub write_dialog_plugin {
	my ($path, $topic, $info_id, $response) = @_;
	write_minimal_plugin($path);
	my $fixture = read_binary($path);
	my $header_end = 16 + unpack('V', substr($fixture, 4, 4));
	my $contents = substr($fixture, 0, $header_end)
		. record_bytes(
			'DIAL',
			subrecord_bytes('NAME', $topic),
			subrecord_bytes('DATA', pack('C', 0)),
		)
		. record_bytes(
			'INFO',
			subrecord_bytes('INAM', $info_id),
			subrecord_bytes('NAME', $response),
		);
	open(my $fh, '>', $path) or die qq{Unable to create "$path": $!};
	binmode($fh, ':raw') or die qq{Unable to set binary mode on "$path": $!};
	print {$fh} $contents or die qq{Unable to write "$path": $!};
	close($fh) or die qq{Unable to close "$path": $!};
}

sub write_plugin_value {
	my ($path, $value) = @_;
	write_minimal_plugin($path);
	open(my $fh, '+<', $path) or die qq{Unable to update "$path": $!};
	binmode($fh, ':raw') or die qq{Unable to set binary mode on "$path": $!};
	seek($fh, -4, 2) or die qq{Unable to seek in "$path": $!};
	print {$fh} pack('l<', $value) or die qq{Unable to update "$path": $!};
	close($fh) or die qq{Unable to close "$path": $!};
}

my $workdir = tempdir(CLEANUP => 1);
my $base = File::Spec->catfile($workdir, 'base.esm');
my $duplicate = File::Spec->catfile($workdir, 'duplicate.esp');
my $override = File::Spec->catfile($workdir, 'override.esp');
write_plugin_value($base, 42);
write_plugin_value($duplicate, 42);
write_plugin_value($override, 43);

subtest 'changed conflicts show their chain and winner' => sub {
	my $result = run_tes3cmd($workdir, 'conflicts', $base, $duplicate, $override);

	is($result->{exit}, 0, 'conflict report succeeds');
	like($result->{stdout}, qr/GMST "ites3cmdtest"/, 'the shared record is reported');
	like($result->{stdout}, qr/base\.esm/, 'the first definition is identified');
	like($result->{stdout}, qr/duplicate\.esp.*identical/, 'an unchanged intermediate definition is identified');
	like($result->{stdout}, qr/override\.esp.*winner.*changed: INTV/, 'the changed winner and subtype are identified');
	like($result->{stdout}, qr/\[1 changed conflict/, 'the changed-conflict count is reported');
};

subtest 'identical duplicates are hidden unless requested' => sub {
	my $hidden = run_tes3cmd($workdir, 'conflicts', $base, $duplicate);
	is($hidden->{exit}, 0, 'default report succeeds');
	unlike($hidden->{stdout}, qr/GMST "ites3cmdtest"/, 'identical duplicate details are hidden');
	like($hidden->{stdout}, qr/1 identical duplicate hidden/, 'the hidden duplicate is counted');

	my $shown = run_tes3cmd($workdir, 'conflicts', '--all', $base, $duplicate);
	is($shown->{exit}, 0, '--all report succeeds');
	like($shown->{stdout}, qr/GMST "ites3cmdtest".*identical/s, 'the identical duplicate is shown');
};

subtest 'standard record selectors narrow the report' => sub {
	my $result = run_tes3cmd(
		$workdir,
		'conflicts',
		'--type',
		'NPC_',
		$base,
		$override,
	);

	is($result->{exit}, 0, 'filtered report succeeds');
	unlike($result->{stdout}, qr/GMST "ites3cmdtest"/, 'nonmatching record types are omitted');
	like($result->{stdout}, qr/\[0 changed conflicts/, 'the empty filtered result is explicit');
};

subtest '--active uses configured load order' => sub {
	my $config = File::Spec->catfile($workdir, 'openmw.cfg');
	open(my $fh, '>', $config) or die qq{Unable to create "$config": $!};
	print {$fh} join(
		"\n",
		qq{data="$workdir"},
		'content=base.esm',
		'content=duplicate.esp',
		'content=override.esp',
		'',
	) or die qq{Unable to write "$config": $!};
	close($fh) or die qq{Unable to close "$config": $!};

	my $result = run_tes3cmd(
		$workdir,
		'conflicts',
		'--active',
		'--openmw-config',
		$config,
	);

	is($result->{exit}, 0, 'active conflict report succeeds');
	like($result->{stdout}, qr/override\.esp.*winner/, 'the final configured plugin wins');
};

subtest 'INFO identity includes its parent dialog' => sub {
	my $first = File::Spec->catfile($workdir, 'first-dialog.esp');
	my $second = File::Spec->catfile($workdir, 'second-dialog.esp');
	write_dialog_plugin($first, 'first topic', 'shared-info-id', 'first response');
	write_dialog_plugin($second, 'second topic', 'shared-info-id', 'second response');

	my $result = run_tes3cmd($workdir, 'conflicts', $first, $second);

	is($result->{exit}, 0, 'dialog conflict report succeeds');
	unlike($result->{stdout}, qr/INFO "shared-info-id"/, 'unrelated dialog entries are not conflated');
	like($result->{stdout}, qr/\[0 changed conflicts/, 'no false conflict is counted');
};

subtest 'at least two plugins are required' => sub {
	my $result = run_tes3cmd($workdir, 'conflicts', $base);

	isnt($result->{exit}, 0, 'one input fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/requires at least two plugins/i,
		'the input requirement is explained',
	);
};

done_testing;
