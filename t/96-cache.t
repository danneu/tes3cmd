use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Storable qw(retrieve store);
use Test2::V0;
use Tes3cmdTest qw(read_binary run_tes3cmd write_minimal_plugin);

sub subrecord {
	my ($type, $data) = @_;
	return pack('a4V', $type, length($data)) . $data;
}

sub record {
	my ($type, $flags, @subrecords) = @_;
	my $payload = join('', @subrecords);
	return pack('a4VVV', $type, length($payload), 0, $flags) . $payload;
}

sub write_binary {
	my ($path, $contents) = @_;
	open(my $fh, '>', $path) or die qq{Unable to create "$path": $!};
	binmode($fh, ':raw') or die qq{Unable to set binary mode on "$path": $!};
	print {$fh} $contents or die qq{Unable to write "$path": $!};
	close($fh) or die qq{Unable to close "$path": $!};
}

sub plugin_bytes {
	my (%options) = @_;
	my $gmst = record(
		'GMST',
		0,
		subrecord('NAME', $options{id}),
		subrecord('INTV', pack('l<', $options{value})),
	);
	my @header_subrecords = subrecord(
		'HEDR',
		pack(
			'f<VZ32Z256V',
			1.3,
			$options{is_master} || 0,
			'tes3cmd tests',
			'cache fixture',
			1,
		),
	);
	if (defined($options{master})) {
		push(
			@header_subrecords,
			subrecord('MAST', "$options{master}\0"),
			subrecord('DATA', pack('V2', $options{master_size}, 0)),
		);
	}
	return record('TES3', 0, @header_subrecords) . $gmst;
}

sub dialogue_plugin_bytes {
	my (%options) = @_;
	my @header_subrecords = subrecord(
		'HEDR',
		pack(
			'f<VZ32Z256V',
			1.3,
			$options{is_master} || 0,
			'tes3cmd tests',
			'dialogue cache fixture',
			scalar(@{$options{dialogues}}) * 2,
		),
	);
	if (defined($options{master})) {
		push(
			@header_subrecords,
			subrecord('MAST', "$options{master}\0"),
			subrecord('DATA', pack('V2', $options{master_size}, 0)),
		);
	}
	my @records = record('TES3', 0, @header_subrecords);
	foreach my $dialogue (@{$options{dialogues}}) {
		push(
			@records,
			record(
				'DIAL',
				0,
				subrecord('NAME', $dialogue->{topic}),
				subrecord('DATA', pack('C', 0)),
			),
			record(
				'INFO',
				0,
				subrecord('INAM', $dialogue->{id}),
				subrecord('NAME', $dialogue->{response}),
			),
		);
	}
	return join('', @records);
}

sub make_install {
	my $installation = tempdir(CLEANUP => 1);
	my $data_files = File::Spec->catdir($installation, 'Data Files');
	make_path($data_files);
	write_binary(
		File::Spec->catfile($installation, 'Morrowind.ini'),
		"[Game Files]\n",
	);
	return ($installation, $data_files);
}

sub write_dependent {
	my ($path, $master_path, $id, $value) = @_;
	write_binary(
		$path,
		plugin_bytes(
			id => $id,
			master => 'Master.esm',
			master_size => -s $master_path,
			value => $value,
		),
	);
}

sub run_clean {
	my ($installation, $plugin, @options) = @_;
	return run_tes3cmd(
		$installation,
		'clean',
		'--morrowind-dir',
		$installation,
		'--dups',
		@options,
		$plugin,
	);
}

subtest 'master cache reuse requires matching schema, codec, and source bytes' => sub {
	my ($installation, $data_files) = make_install();
	my $master = File::Spec->catfile($data_files, 'Master.esm');
	my $probe = File::Spec->catfile($data_files, 'Probe.esp');
	write_binary($master, plugin_bytes(id => 'iCacheValue', is_master => 1, value => 42));
	write_dependent($probe, $master, 'iOtherValue', 7);

	my $first = run_clean($installation, $probe);
	is($first->{exit}, 0, 'first master lookup succeeds');
	like($first->{stdout}, qr/Loading Master: master\.esm/, 'first lookup parses the master');
	my $cache = File::Spec->catfile($installation, 'tes3cmd', 'cache', 'master.esm.cache');
	ok(-f $cache, 'master cache is created');
	my $stored = retrieve($cache);
	is($stored->{schema_version}, 2, 'master cache records its schema');
	is($stored->{codec_version}, '0.3', 'master cache records its codec version');
	like($stored->{source}->{sha256}, qr/^[0-9a-f]{64}$/, 'master cache records a SHA-256 source fingerprint');

	my $second = run_clean($installation, $probe);
	is($second->{exit}, 0, 'compatible cache lookup succeeds');
	like($second->{stdout}, qr/Loaded cached Master:/, 'compatible cache is reused');
	my $cache_bytes = read_binary($cache);
	my $uncached = run_clean($installation, $probe, '--no-cache');
	is($uncached->{exit}, 0, 'uncached master lookup succeeds');
	unlike($uncached->{stdout}, qr/Loaded cached Master:/, '--no-cache bypasses the master cache');
	is(read_binary($cache), $cache_bytes, '--no-cache leaves the master cache untouched');

	$stored = retrieve($cache);
	$stored->{schema_version} = 1;
	store($stored, $cache);
	my $schema = run_clean($installation, $probe);
	is($schema->{exit}, 0, 'schema mismatch is rebuilt successfully');
	like($schema->{stdout} . $schema->{stderr}, qr/schema mismatch/, 'schema mismatch is reported');
	is(retrieve($cache)->{schema_version}, 2, 'schema mismatch is replaced with the current schema');

	$stored = retrieve($cache);
	$stored->{codec_version} = 'old-codec';
	store($stored, $cache);
	my $codec = run_clean($installation, $probe);
	is($codec->{exit}, 0, 'codec mismatch is rebuilt successfully');
	like($codec->{stdout} . $codec->{stderr}, qr/codec mismatch/, 'codec mismatch is reported');
	is(retrieve($cache)->{codec_version}, '0.3', 'codec mismatch is replaced with the current codec');

	write_binary($cache, 'not a Storable cache');
	my $corrupt = run_clean($installation, $probe);
	is($corrupt->{exit}, 0, 'corrupted cache is rebuilt successfully');
	like($corrupt->{stdout} . $corrupt->{stderr}, qr/Cache|Storable|retrieve/i, 'corrupted cache is reported');
	is(retrieve($cache)->{schema_version}, 2, 'corrupted cache is replaced with valid data');
};

subtest 'same-size master changes cannot drive stale cleaning decisions' => sub {
	my ($installation, $data_files) = make_install();
	my $master = File::Spec->catfile($data_files, 'Master.esm');
	my $probe = File::Spec->catfile($data_files, 'Probe.esp');
	my $target = File::Spec->catfile($data_files, 'Target.esp');
	write_binary($master, plugin_bytes(id => 'iCacheValue', is_master => 1, value => 42));
	write_dependent($probe, $master, 'iOtherValue', 7);
	write_dependent($target, $master, 'iCacheValue', 42);
	run_clean($installation, $probe);
	my $cache = File::Spec->catfile($installation, 'tes3cmd', 'cache', 'master.esm.cache');
	my $old_fingerprint = retrieve($cache)->{source}->{sha256};
	my $old_size = -s $master;

	write_binary($master, plugin_bytes(id => 'iCacheValue', is_master => 1, value => 43));
	is(-s $master, $old_size, 'changed master has the same size');
	my $result = run_clean($installation, $target);
	is($result->{exit}, 0, 'clean succeeds after same-size master change');
	like($result->{stdout} . $result->{stderr}, qr/source changed/, 'same-size source change invalidates the cache');
	like(run_tes3cmd($installation, 'dump', '--type', 'GMST', $target)->{stdout}, qr/iCacheValue/, 'target record is not deleted using stale master data');
	ok(!-e File::Spec->catfile($data_files, 'Clean_Target.esp'), 'no stale cleaned output is produced');
	isnt(retrieve($cache)->{source}->{sha256}, $old_fingerprint, 'rebuilt cache fingerprints current master bytes');
};

subtest 'duplicate INFO lookup is scoped to its parent DIAL' => sub {
	my ($installation, $data_files) = make_install();
	my $master = File::Spec->catfile($data_files, 'Master.esm');
	my $target = File::Spec->catfile($data_files, 'Target.esp');
	write_binary(
		$master,
		dialogue_plugin_bytes(
			is_master => 1,
			dialogues => [
				{topic => 'topic a', id => 'shared-info', response => 'master response a'},
				{topic => 'topic b', id => 'shared-info', response => 'master response b'},
			],
		),
	);
	write_binary(
		$target,
		dialogue_plugin_bytes(
			master => 'Master.esm',
			master_size => -s $master,
			dialogues => [
				{topic => 'topic a', id => 'shared-info', response => 'master response b'},
				{topic => 'topic b', id => 'shared-info', response => 'master response b'},
			],
		),
	);

	my $result = run_clean($installation, $target);
	is($result->{exit}, 0, 'dialogue duplicate cleaning succeeds');
	my $cleaned = File::Spec->catfile($data_files, 'Clean_Target.esp');
	ok(-f $cleaned, 'the genuine duplicate produces cleaned output');
	my $dump = run_tes3cmd(
		$installation,
		'dump',
		'--type',
		'INFO',
		$cleaned,
	);
	is($dump->{exit}, 0, 'cleaned dialogue output can be read');
	like($dump->{stdout}, qr/Topic:topic a/, 'the non-duplicate INFO remains under its parent topic');
	unlike($dump->{stdout}, qr/Topic:topic b/, 'the genuine duplicate INFO is removed');
};

subtest 'leveled-list cache tracks source bytes and --no-cache leaves it untouched' => sub {
	my ($installation, $data_files) = make_install();
	my $active = File::Spec->catfile($data_files, 'Active.esp');
	write_minimal_plugin($active);
	write_binary(
		File::Spec->catfile($installation, 'Morrowind.ini'),
		"[Game Files]\nGameFile0=Active.esp\n",
	);
	my @command = (
		'multipatch',
		'--morrowind-dir',
		$installation,
		'--merge-lists',
		'--no-activate',
	);
	my $first = run_tes3cmd($installation, @command);
	is($first->{exit}, 0, 'first multipatch cache run succeeds');
	my $cache = File::Spec->catfile($installation, 'tes3cmd', 'cache', 'leveled_lists_data.cache');
	ok(-f $cache, 'leveled-list cache is created');
	my $stored = retrieve($cache);
	is($stored->{_schema_version_}, 1, 'aggregate cache records its schema');
	is($stored->{_codec_version_}, '0.3', 'aggregate cache records its codec');
	my $old_fingerprint = $stored->{'active.esp'}->{_source_}->{sha256};

	my $contents = read_binary($active);
	substr($contents, -1, 1, chr((ord(substr($contents, -1, 1)) + 1) % 256));
	write_binary($active, $contents);
	my $changed = run_tes3cmd($installation, @command, '--overwrite');
	is($changed->{exit}, 0, 'multipatch succeeds after same-size source change');
	like($changed->{stdout} . $changed->{stderr}, qr/Cache UPDATING: Active\.esp/, 'same-size active-plugin change invalidates its entry');
	isnt(retrieve($cache)->{'active.esp'}->{_source_}->{sha256}, $old_fingerprint, 'aggregate cache stores the new fingerprint');

	my $cache_bytes = read_binary($cache);
	my $uncached = run_tes3cmd($installation, @command, '--no-cache', '--overwrite');
	is($uncached->{exit}, 0, '--no-cache operation succeeds');
	is(read_binary($cache), $cache_bytes, '--no-cache neither reads nor rewrites the existing cache');

	$stored = retrieve($cache);
	$stored->{_schema_version_} = 0;
	store($stored, $cache);
	my $schema = run_tes3cmd($installation, @command, '--overwrite');
	is($schema->{exit}, 0, 'aggregate schema mismatch is rebuilt');
	like($schema->{stdout} . $schema->{stderr}, qr/schema update/, 'aggregate schema mismatch is reported');
	is(retrieve($cache)->{_schema_version_}, 1, 'aggregate cache is rewritten with the current schema');
};

done_testing;
