use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(read_binary run_tes3cmd write_minimal_plugin);

sub subrecord_bytes {
	my ($type, $payload, $declared_length) = @_;
	$declared_length = length($payload) unless defined $declared_length;
	return pack('a4V', $type, $declared_length) . $payload;
}

sub record_bytes {
	my ($type, $payload, $declared_length) = @_;
	$declared_length = length($payload) unless defined $declared_length;
	return pack('a4VVV', $type, $declared_length, 0, 0) . $payload;
}

sub fixture_records {
	my ($workdir) = @_;
	my $fixture = File::Spec->catfile($workdir, 'fixture.esp');
	write_minimal_plugin($fixture);
	my $bytes = read_binary($fixture);
	my $header_length = unpack('V', substr($bytes, 4, 4));
	my $header_end = 16 + $header_length;
	return (substr($bytes, 0, $header_end), substr($bytes, $header_end));
}

sub write_binary {
	my ($path, $contents) = @_;
	open(my $fh, '>', $path) or die qq{Unable to create "$path": $!};
	binmode($fh, ':raw') or die qq{Unable to set binary mode on "$path": $!};
	print {$fh} $contents or die qq{Unable to write "$path": $!};
	close($fh) or die qq{Unable to close "$path": $!};
}

sub run_dump_fixture {
	my ($name, $contents) = @_;
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, $name);
	write_binary($plugin, $contents);
	return ($plugin, run_tes3cmd($workdir, 'dump', $plugin));
}

my $fixture_dir = tempdir(CLEANUP => 1);
my ($tes3_record, $gmst_record) = fixture_records($fixture_dir);

subtest 'truncated record header is rejected with context' => sub {
	my ($plugin, $result) = run_dump_fixture(
		'truncated-header.esp',
		$tes3_record . substr($gmst_record, 0, 7),
	);

	isnt($result->{exit}, 0, 'dump fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/\Q$plugin\E.*header.*byte: \d+.*asked for 16 bytes, got 7/is,
		'the failure identifies the plugin, offset, and short header',
	);
};

subtest 'record payload beyond EOF is rejected before decoding' => sub {
	my ($plugin, $result) = run_dump_fixture(
		'truncated-record.esp',
		$tes3_record . record_bytes('GMST', 'short', 100),
	);

	isnt($result->{exit}, 0, 'dump fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/\Q$plugin\E.*rec_type="GMST".*asked for 100 bytes, got 5/is,
		'the failure identifies the record type and available payload',
	);
};

subtest 'normal commands require TES3 as the initial record' => sub {
	my ($plugin, $result) = run_dump_fixture('missing-tes3.esp', $gmst_record);

	isnt($result->{exit}, 0, 'dump fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/\Q$plugin\E.*byte: 0.*Expected: "TES3", got: "GMST"/is,
		'the failure identifies the incorrect initial record',
	);
};

subtest 'empty input is not accepted as an empty plugin' => sub {
	my ($plugin, $result) = run_dump_fixture('empty.esp', '');

	isnt($result->{exit}, 0, 'dump fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/\Q$plugin\E.*missing TES3 header/is,
		'the missing header is reported',
	);
};

subtest 'multi-plugin readers also require TES3 first' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $invalid = File::Spec->catfile($workdir, 'invalid.esp');
	my $valid = File::Spec->catfile($workdir, 'valid.esp');
	write_binary($invalid, $gmst_record);
	write_binary($valid, $tes3_record . $gmst_record);

	my $result = run_tes3cmd($workdir, 'common', $invalid, $valid);

	isnt($result->{exit}, 0, 'common fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/\Q$invalid\E.*byte: 0.*Expected: "TES3", got: "GMST"/is,
		'the invalid input is identified',
	);
};

subtest 'truncated subrecord header is rejected at its absolute offset' => sub {
	my $bad_record = record_bytes('GMST', 'NAME');
	my ($plugin, $result) = run_dump_fixture(
		'truncated-subrecord-header.esp',
		$tes3_record . $bad_record,
	);

	isnt($result->{exit}, 0, 'dump fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/\Q$plugin\E.*record "GMST".*subrecord header.*byte: \d+.*needed 8 bytes, got 4/is,
		'the failure includes record type, absolute offset, and remaining bytes',
	);
};

subtest 'subrecord payload cannot cross its record boundary' => sub {
	my $payload = subrecord_bytes('NAME', 'abc', 20);
	my ($plugin, $result) = run_dump_fixture(
		'truncated-subrecord-payload.esp',
		$tes3_record . record_bytes('GMST', $payload),
	);

	isnt($result->{exit}, 0, 'dump fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/\Q$plugin\E.*GMST\.NAME.*byte: \d+.*declares 20 bytes, only 3 remain/is,
		'the failure identifies the subrecord and its invalid boundary',
	);
};

subtest 'unknown records are rejected without rewriting the plugin' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'unknown.esp');
	my $contents = $tes3_record . record_bytes(
		'ZZZZ',
		subrecord_bytes('ABCD', 'opaque'),
	);
	write_binary($plugin, $contents);

	my $result = run_tes3cmd($workdir, 'delete', '--type', 'STAT', $plugin);

	isnt($result->{exit}, 0, 'the unsupported record fails the command');
	is(read_binary($plugin), $contents, 'the unknown record is preserved byte-for-byte');
	like(
		$result->{stdout} . $result->{stderr},
		qr/\Q$plugin\E.*byte: \d+.*Unknown Record Type: "ZZZZ"/is,
		'the failure identifies the plugin, offset, and unknown type',
	);
	is([glob("$plugin.tmp.*")], [], 'no temporary output remains');
};

subtest 'well-bounded unknown subrecords remain compatible' => sub {
	my $payload = subrecord_bytes('NAME', 'iKnownId')
		. subrecord_bytes('ZZZZ', 'opaque');
	my ($plugin, $result) = run_dump_fixture(
		'unknown-subrecord.esp',
		$tes3_record . record_bytes('GMST', $payload),
	);

	is($result->{exit}, 0, 'dump succeeds');
	like($result->{stdout}, qr/Record: GMST "iknownid"/, 'the known data is decoded');
	like(
		$result->{stdout} . $result->{stderr},
		qr/unknown subtype: GMST::ZZZZ/i,
		'the bounded unknown subtype is reported',
	);
};

subtest 'recover remains the explicit tolerant path' => sub {
	my $workdir = tempdir(CLEANUP => 1);
	my $plugin = File::Spec->catfile($workdir, 'recoverable.esp');
	my $damaged = $tes3_record . 'JUNK!' . $gmst_record;
	write_binary($plugin, $damaged);

	my $result = run_tes3cmd($workdir, 'recover', $plugin);

	is($result->{exit}, 0, 'recover succeeds');
	like($result->{stdout}, qr/Removed 1 section of bad data/, 'recover reports discarded junk');
	is(
		read_binary(File::Spec->catfile($workdir, 'recoverable~1.esp')),
		$damaged,
		'recover backs up the damaged input',
	);
	my $dump = run_tes3cmd($workdir, 'dump', '--type', 'GMST', $plugin);
	is($dump->{exit}, 0, 'the recovered plugin is readable normally');
	like($dump->{stdout}, qr/Record: GMST/, 'the record after the junk was recovered');
};

done_testing;
