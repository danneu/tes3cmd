use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(read_binary run_tes3cmd write_minimal_plugin);

sub write_binary {
	my ($path, $contents) = @_;
	open(my $fh, '>', $path) or die qq{Unable to create "$path": $!};
	binmode($fh, ':raw') or die qq{Unable to set binary mode on "$path": $!};
	print {$fh} $contents or die qq{Unable to write "$path": $!};
	close($fh) or die qq{Unable to close "$path": $!};
}

sub record_bytes {
	my ($type, $payload, $declared_length) = @_;
	$declared_length = length($payload) unless defined $declared_length;
	return pack('a4VVV', $type, $declared_length, 0, 0) . $payload;
}

sub subrecord_bytes {
	my ($type, $payload, $declared_length) = @_;
	$declared_length = length($payload) unless defined $declared_length;
	return pack('a4V', $type, $declared_length) . $payload;
}

sub fixture_records {
	my ($workdir) = @_;
	my $fixture = File::Spec->catfile($workdir, 'fixture.esp');
	write_minimal_plugin($fixture);
	my $bytes = read_binary($fixture);
	my $header_end = 16 + unpack('V', substr($bytes, 4, 4));
	return (substr($bytes, 0, $header_end), substr($bytes, $header_end));
}

sub assert_not_replaced {
	my ($workdir, $name, $contents, $description) = @_;
	my $plugin = File::Spec->catfile($workdir, $name);
	write_binary($plugin, $contents);

	my $result = run_tes3cmd($workdir, 'recover', $plugin);

	is($result->{exit}, 0, "$description is handled without crashing");
	like($result->{stdout}, qr/Unable to recover data/, "$description is reported as unrecoverable");
	is(read_binary($plugin), $contents, "$description is not replaced");
	my $backup = $plugin;
	$backup =~ s/\.esp$/~1.esp/;
	ok(!-e $backup, "$description creates no backup");
}

my $fixture_dir = tempdir(CLEANUP => 1);
my ($tes3_record, $gmst_record) = fixture_records($fixture_dir);

subtest 'record-type bytes without a complete record are ignored' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $damaged = $tes3_record . 'junk GMST' . pack('V', 100) . 'short';
	assert_not_replaced(
		$workdir,
		'false-signature.esp',
		$damaged,
		'a false record-type signature',
	);
};

subtest 'truncated final records cannot produce header-only replacements' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $damaged = $tes3_record . substr($gmst_record, 0, 12);
	assert_not_replaced(
		$workdir,
		'truncated.esp',
		$damaged,
		'a truncated record',
	);
};

subtest 'complete records before a truncated tail can be recovered' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'truncated-tail.esp');
	my $damaged = $tes3_record . $gmst_record . substr($gmst_record, 0, 12);
	write_binary($plugin, $damaged);

	my $result = run_tes3cmd($workdir, 'recover', $plugin);

	is($result->{exit}, 0, 'recovery succeeds');
	like($result->{stdout}, qr/Removed 1 section of bad data/, 'the truncated tail is reported');
	is(
		read_binary($plugin),
		$tes3_record . $gmst_record,
		'the complete non-header record is retained',
	);
	is(
		read_binary(File::Spec->catfile($workdir, 'truncated-tail~1.esp')),
		$damaged,
		'the input with the truncated tail is backed up',
	);
};

subtest 'invalid candidate structure is skipped for a later valid record' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'invalid-candidate.esp');
	my $false_record = record_bytes(
		'GMST',
		subrecord_bytes('NAME', 'fake', 100),
	);
	my $damaged = $tes3_record . 'junk' . $false_record . 'more junk' . $gmst_record;
	write_binary($plugin, $damaged);

	my $result = run_tes3cmd($workdir, 'recover', $plugin);

	is($result->{exit}, 0, 'recovery succeeds');
	is(
		read_binary($plugin),
		$tes3_record . $gmst_record,
		'the malformed candidate is discarded and the valid record is recovered',
	);
	is(
		read_binary(File::Spec->catfile($workdir, 'invalid-candidate~1.esp')),
		$damaged,
		'the damaged input is backed up',
	);
};

subtest 'a corrupt declared record length can be bypassed conservatively' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'corrupt-length.esp');
	my $damaged = $tes3_record . record_bytes('GMST', 'broken', 1000) . $gmst_record;
	write_binary($plugin, $damaged);

	my $result = run_tes3cmd($workdir, 'recover', $plugin);

	is($result->{exit}, 0, 'recovery succeeds');
	is(
		read_binary($plugin),
		$tes3_record . $gmst_record,
		'the record with the corrupt declared length is discarded',
	);
};

subtest 'a missing TES3 header is never reconstructed from later records' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $damaged = 'damaged header' . $gmst_record;
	assert_not_replaced(
		$workdir,
		'missing-header.esp',
		$damaged,
		'an input without an initial TES3 header',
	);
};

done_testing;
