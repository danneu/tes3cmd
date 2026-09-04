use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(read_binary run_command run_tes3cmd tes3cmd_path);

sub subrecord {
	my ($type, $data) = @_;
	return pack('a4V', $type, length($data)) . $data;
}

sub record {
	my ($type, $flags, @subrecords) = @_;
	my $payload = join('', @subrecords);
	return pack('a4VVV', $type, length($payload), 0, $flags) . $payload;
}

sub header_record {
	my ($count, @extra) = @_;
	return record(
		'TES3',
		0,
		subrecord(
			'HEDR',
			pack('f<VZ32Z256V', 1.3, 0, 'wire tests', 'generated fixture', $count),
		),
		@extra,
	);
}

sub write_binary {
	my ($path, $contents) = @_;
	open(my $fh, '>', $path) or die qq{Unable to create "$path": $!};
	binmode($fh, ':raw') or die qq{Unable to set binary mode on "$path": $!};
	print {$fh} $contents or die qq{Unable to write "$path": $!};
	close($fh) or die qq{Unable to close "$path": $!};
}

sub parse_plugin {
	my ($contents) = @_;
	my @records;
	my $offset = 0;
	while ($offset < length($contents)) {
		my ($type, $length, undef, $flags) = unpack('a4VVV', substr($contents, $offset, 16));
		my $payload = substr($contents, $offset + 16, $length);
		my @subrecords;
		my $suboffset = 0;
		while ($suboffset < length($payload)) {
			my ($subtype, $sublength) = unpack('a4V', substr($payload, $suboffset, 8));
			push(@subrecords, {
				type => $subtype,
				data => substr($payload, $suboffset + 8, $sublength),
			});
			$suboffset += 8 + $sublength;
		}
		push(@records, {type => $type, flags => $flags, subrecords => \@subrecords});
		$offset += 16 + $length;
	}
	return \@records;
}

sub wire_fixture {
	my @records = (
		record('ARMO', 0, subrecord('NAME', "armor-term\0"), subrecord('BNAM', "old-armor-term\0")),
		record('ARMO', 0, subrecord('NAME', "armor-plain\0"), subrecord('BNAM', 'old-armor-plain')),
		record('CLOT', 0, subrecord('NAME', "clot-term\0"), subrecord('CNAM', "old-clot-term\0")),
		record('CLOT', 0, subrecord('NAME', "clot-plain\0"), subrecord('CNAM', 'old-clot-plain')),
		record('GMST', 0, subrecord('NAME', "old-gmst-term\0"), subrecord('INTV', pack('l<', 42))),
		record('GMST', 0, subrecord('NAME', 'old-gmst-plain'), subrecord('INTV', pack('l<', 43))),
		record('SSCR', 0, subrecord('DATA', "old-sscr-data-term\0"), subrecord('NAME', "old-sscr-name-term\0")),
		record('SSCR', 0, subrecord('DATA', 'old-sscr-data-plain'), subrecord('NAME', 'old-sscr-name-plain')),
	);
	return header_record(scalar(@records)) . join('', @records);
}

sub asymmetric_payloads {
	my ($contents) = @_;
	my @payloads;
	foreach my $record (@{parse_plugin($contents)}) {
		my %wanted = (
			ARMO => {BNAM => 1},
			CLOT => {CNAM => 1},
			GMST => {NAME => 1},
			SSCR => {DATA => 1, NAME => 1},
		);
		next unless $wanted{$record->{type}};
		foreach my $subrecord (@{$record->{subrecords}}) {
			push(@payloads, $subrecord->{data})
				if $wanted{$record->{type}}->{$subrecord->{type}};
		}
	}
	return @payloads;
}

my $workdir = tempdir(CLEANUP => 1);

subtest 'strict codec verification reconstructs both trailing-NUL conventions' => sub {
	my $plugin = File::Spec->catfile($workdir, 'wire.esp');
	write_binary($plugin, wire_fixture());
	my $result = run_tes3cmd($workdir, '-testcodec', $plugin);
	my $round_trip = File::Spec->catfile($workdir, 'test_wire.esp');

	is($result->{exit}, 0, 'strict codec verification succeeds');
	unlike($result->{stdout} . $result->{stderr}, qr/CODEC FAILURE/, 'no codec mismatch is hidden or reported');
	is(read_binary($round_trip), read_binary($plugin), 'forced re-encoding is byte-identical');
};

subtest 'unrelated set changes preserve every untouched subrecord byte' => sub {
	my $plugin = File::Spec->catfile($workdir, 'set.esp');
	write_binary($plugin, wire_fixture());
	my $before = parse_plugin(read_binary($plugin));
	my ($before_record) = grep { $_->{type} eq 'GMST' } @{$before};

	my $result = run_tes3cmd(
		$workdir,
		'modify',
		'--type', 'GMST',
		'--exact-id', 'old-gmst-term',
		'--run', '$R->set({f=>"integer"}, 99)',
		$plugin,
	);
	my $after = parse_plugin(read_binary($plugin));
	my ($after_record) = grep { $_->{type} eq 'GMST' } @{$after};

	is($result->{exit}, 0, 'set mutation succeeds');
	is($after_record->{subrecords}->[0], $before_record->{subrecords}->[0], 'the untouched terminated NAME is byte-identical');
	is(unpack('l<', $after_record->{subrecords}->[1]->{data}), 99, 'the selected INTV is re-encoded');
};

subtest 'modify replacement retains each original trailing-NUL convention' => sub {
	my $plugin = File::Spec->catfile($workdir, 'replace.esp');
	write_binary($plugin, wire_fixture());
	my @before = asymmetric_payloads(read_binary($plugin));
	my $result = run_tes3cmd($workdir, 'modify', '--replace', '/old/new/', $plugin);
	my @after = asymmetric_payloads(read_binary($plugin));

	is($result->{exit}, 0, 'replacement succeeds');
	is(scalar(@after), 10, 'all asymmetric fixture fields remain present');
	foreach my $index (0 .. $#after) {
		like($after[$index], qr/new/, "field $index is changed");
		is(
			substr($after[$index], -1, 1) eq "\0",
			substr($before[$index], -1, 1) eq "\0",
			"field $index retains its trailing-NUL convention",
		);
	}
};

subtest 'new asymmetric subrecords use the unterminated canonical form' => sub {
	my $plugin = File::Spec->catfile($workdir, 'new-subrecord.esp');
	my $armo = record('ARMO', 0, subrecord('NAME', "new-armor\0"));
	write_binary($plugin, header_record(1) . $armo);

	my $result = run_tes3cmd(
		$workdir,
		'modify',
		'--type', 'ARMO',
		'--run', '$R->append(ARMO::BNAM->new({male_body_id=>"created"}))',
		$plugin,
	);
	my ($record) = grep { $_->{type} eq 'ARMO' } @{parse_plugin(read_binary($plugin))};
	my ($bnam) = grep { $_->{type} eq 'BNAM' } @{$record->{subrecords}};

	is($result->{exit}, 0, 'new subrecord mutation succeeds');
	is($bnam->{data}, 'created', 'new asymmetric value is unterminated');
};

subtest 'header and CELL mutation paths retain intended changes' => sub {
	my $header_plugin = File::Spec->catfile($workdir, 'header.esp');
	my $master_wire = "Master.esm\0trailing-wire-data";
	write_binary($header_plugin, header_record(0, subrecord('MAST', $master_wire)));
	my $header_result = run_tes3cmd($workdir, 'header', '--author', 'revised', $header_plugin);
	my ($tes3) = grep { $_->{type} eq 'TES3' } @{parse_plugin(read_binary($header_plugin))};
	my ($hedr) = grep { $_->{type} eq 'HEDR' } @{$tes3->{subrecords}};
	my ($mast) = grep { $_->{type} eq 'MAST' } @{$tes3->{subrecords}};
	my (undef, undef, $author) = unpack('f<VZ32', $hedr->{data});

	is($header_result->{exit}, 0, 'header mutation succeeds');
	is($author, 'revised', 'the header field change is encoded');
	is($mast->{data}, $master_wire, 'an untouched header subrecord retains noncanonical wire bytes');

	my $cell_plugin = File::Spec->catfile($workdir, 'cell.esp');
	my $cell = record(
		'CELL',
		0,
		subrecord('NAME', "Wire Cell\0"),
		subrecord('DATA', pack('LLf', 1, 0, 0.25)),
		subrecord('AMBI', pack('LLLf', 0, 0, 0, 0.25)),
	);
	write_binary($cell_plugin, header_record(1) . $cell);
	my $cell_result = run_tes3cmd(
		$workdir,
		'modify',
		'--type', 'CELL',
		'--run', '$R->get("AMBI")->{fog_density}=0.5; $R->modified(1)',
		$cell_plugin,
	);
	my ($updated_cell) = grep { $_->{type} eq 'CELL' } @{parse_plugin(read_binary($cell_plugin))};
	my ($ambi) = grep { $_->{type} eq 'AMBI' } @{$updated_cell->{subrecords}};
	my (undef, undef, undef, $fog_density) = unpack('LLLf', $ambi->{data});

	is($cell_result->{exit}, 0, 'CELL field mutation succeeds');
	is($fog_density, 0.5, 'a direct CELL field change is detected and encoded');
};

subtest 'forced re-encoding detects a deliberately incorrect codec' => sub {
	my $plugin = File::Spec->catfile($workdir, 'broken-codec.esp');
	write_binary(
		$plugin,
		header_record(1) . record(
			'GMST', 0,
			subrecord('NAME', 'iBrokenCodec'),
			subrecord('INTV', pack('l<', 70000)),
		),
	);
	my $broken_script = File::Spec->catfile($workdir, 'tes3cmd-broken');
	my $source = read_binary(tes3cmd_path());
	is(
		($source =~ s/\[INTV => \[\["integer", "l"\]\]\],/[INTV => [["integer", "s"]]],/),
		1,
		'the temporary script changes exactly one codec definition',
	);
	write_binary($broken_script, $source);
	my $result = run_command($workdir, $^X, $broken_script, '-testcodec', $plugin);

	isnt($result->{exit}, 0, 'the broken codec fails verification');
	like($result->{stdout} . $result->{stderr}, qr/CODEC FAILURE/, 'the forced path reports the mismatch');
};

done_testing;
