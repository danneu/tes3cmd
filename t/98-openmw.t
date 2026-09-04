use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test2::V0;
use Tes3cmdTest qw(
	read_binary
	run_tes3cmd
	run_tes3cmd_with_env
	write_minimal_plugin
);

sub write_text {
	my ($path, $contents) = @_;
	open(my $fh, '>', $path) or die qq{Unable to create "$path": $!};
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

sub make_openmw_setup {
	my $root = tempdir(CLEANUP => 1);
	my $base = File::Spec->catdir($root, 'base data');
	my $mods = File::Spec->catdir($root, 'mods');
	my $local = File::Spec->catdir($root, 'local');
	make_path($base, $mods, $local);

	write_plugin_value(File::Spec->catfile($base, 'Shared.esp'), 41);
	write_plugin_value(File::Spec->catfile($mods, 'shared.ESP'), 42);
	write_plugin_value(File::Spec->catfile($local, 'SHARED.ESP'), 43);
	write_plugin_value(File::Spec->catfile($base, 'First.esm'), 1);
	write_plugin_value(File::Spec->catfile($mods, 'Second.esp'), 2);

	my $config = File::Spec->catfile($root, 'openmw.cfg');
	write_text(
		$config,
		join(
			"\n",
			'# OpenMW test configuration',
			'data="base data"',
			'data=mods',
			'data-local=local',
			'content=First.esm',
			'content=Second.esp',
			'content=Missing.esp',
			'',
		),
	);
	return ($root, $config, $base, $mods, $local);
}

subtest 'explicit OpenMW configuration resolves the winning data path' => sub {
	my ($root, $config) = make_openmw_setup();
	my $result = run_tes3cmd(
		$root,
		'dump',
		'--openmw-config',
		$config,
		'--type',
		'GMST',
		'SHARED.esp',
	);

	is($result->{exit}, 0, 'dump succeeds');
	like($result->{stdout}, qr/Integer:43/, 'data-local overrides every regular data directory');
};

subtest 'OpenMW content order is preserved independently of timestamps' => sub {
	my ($root, $config, $base, $mods) = make_openmw_setup();
	utime(2_000_000_000, 2_000_000_000, File::Spec->catfile($base, 'First.esm'));
	utime(1_000_000_000, 1_000_000_000, File::Spec->catfile($mods, 'Second.esp'));

	my $result = run_tes3cmd($root, 'active', '--openmw-config', $config);

	is($result->{exit}, 0, 'active listing succeeds');
	like(
		$result->{stdout},
		qr/\[LOAD ORDER\]\nFirst\.esm\nSecond\.esp\n\[2 Active Plugins\]/,
		'configured content order is retained and missing content is omitted',
	);
};

subtest 'OpenMW profile configuration is composed in priority order' => sub {
	my ($root, undef, $base, $mods, $local) = make_openmw_setup();
	my $profile = File::Spec->catdir($root, 'profile');
	make_path($profile);
	my $config = File::Spec->catfile($root, 'composed.cfg');
	write_text(
		$config,
		join(
			"\n",
			qq{data="$base"},
			'content=First.esm',
			'config=profile',
			'',
		),
	);
	write_text(
		File::Spec->catfile($profile, 'openmw.cfg'),
		join(
			"\n",
			qq{data="$mods"},
			qq{data-local="$local"},
			'content=Second.esp',
			'',
		),
	);

	my $result = run_tes3cmd($root, 'active', '--openmw-config', $config);

	is($result->{exit}, 0, 'composed configuration loads');
	like(
		$result->{stdout},
		qr/First\.esm\nSecond\.esp/,
		'lower- and higher-priority content entries retain their order',
	);
};

subtest 'OpenMW replace directives discard lower-priority lists' => sub {
	my ($root, undef, $base, $mods) = make_openmw_setup();
	my $profile = File::Spec->catdir($root, 'replacement');
	make_path($profile);
	my $config = File::Spec->catfile($root, 'replace.cfg');
	write_text(
		$config,
		join(
			"\n",
			qq{data="$base"},
			'content=First.esm',
			'config=replacement',
			'',
		),
	);
	write_text(
		File::Spec->catfile($profile, 'openmw.cfg'),
		join(
			"\n",
			'replace=data',
			'replace=content',
			qq{data="$mods"},
			'content=Second.esp',
			'',
		),
	);

	my $active = run_tes3cmd($root, 'active', '--openmw-config', $config);
	is($active->{exit}, 0, 'replacement profile loads');
	like($active->{stdout}, qr/Second\.esp/, 'higher-priority content remains');
	unlike($active->{stdout}, qr/First\.esm/, 'lower-priority content is removed');

	my $missing = run_tes3cmd($root, 'dump', '--openmw-config', $config, 'First.esm');
	isnt($missing->{exit}, 0, 'a plugin from the replaced data list is not resolved');
};

subtest 'OpenMW configuration is read-only' => sub {
	my ($root, $config) = make_openmw_setup();
	my $before = read_binary($config);
	my $result = run_tes3cmd(
		$root,
		'active',
		'--openmw-config',
		$config,
		'--on',
		'Shared.esp',
	);

	isnt($result->{exit}, 0, 'activation fails');
	like(
		$result->{stdout} . $result->{stderr},
		qr/OpenMW configuration is read-only/i,
		'the read-only boundary is explained',
	);
	is(read_binary($config), $before, 'openmw.cfg remains byte-for-byte unchanged');

	my $noop = run_tes3cmd(
		$root,
		'active',
		'--openmw-config',
		$config,
		'--on',
		'First.esm',
	);
	isnt($noop->{exit}, 0, 'an already-active no-op is also rejected');
	is(read_binary($config), $before, 'the no-op request does not touch openmw.cfg');
};

subtest 'explicit location options are mutually exclusive' => sub {
	my ($root, $config, $base) = make_openmw_setup();
	my $result = run_tes3cmd(
		$root,
		'dump',
		'--openmw-config',
		$config,
		'--data-files',
		$base,
		'Shared.esp',
	);

	isnt($result->{exit}, 0, 'conflicting locations fail');
	like(
		$result->{stdout} . $result->{stderr},
		qr/cannot be used together/,
		'the precedence conflict is explicit',
	);
};

subtest 'standalone paths remain independent of OpenMW configuration' => sub {
	my ($root, $config) = make_openmw_setup();
	my $standalone = File::Spec->catfile($root, 'standalone.esp');
	write_plugin_value($standalone, 77);

	my $dump = run_tes3cmd($root, 'dump', '--type', 'GMST', $standalone);
	my $diff = run_tes3cmd($root, 'diff', $standalone, $standalone);

	is($dump->{exit}, 0, 'standalone dump succeeds');
	like($dump->{stdout}, qr/Integer:77/, 'standalone dump reads the explicit path');
	is($diff->{exit}, 0, 'standalone diff succeeds');
};

subtest 'automatic discovery prefers a nearby classic installation' => sub {
	my ($openmw_root, $config, $base, $mods, $local) = make_openmw_setup();
	my $fake_home = File::Spec->catdir($openmw_root, 'home');
	my $default_config_dir;
	my %environment = (HOME => $fake_home);
	if ($^O eq 'darwin') {
		$default_config_dir = File::Spec->catdir(
			$fake_home,
			'Library',
			'Preferences',
			'openmw',
		);
	} elsif ($^O =~ /^MSWin/) {
		$default_config_dir = File::Spec->catdir(
			$fake_home,
			'Documents',
			'My Games',
			'OpenMW',
		);
		$environment{USERPROFILE} = $fake_home;
	} else {
		my $config_home = File::Spec->catdir($fake_home, 'config');
		$environment{XDG_CONFIG_HOME} = $config_home;
		$default_config_dir = File::Spec->catdir($config_home, 'openmw');
	}
	make_path($default_config_dir);
	write_text(
		File::Spec->catfile($default_config_dir, 'openmw.cfg'),
		join(
			"\n",
			qq{data="$base"},
			qq{data="$mods"},
			qq{data-local="$local"},
			'content=First.esm',
			'content=Second.esp',
			'',
		),
	);

	my $outside = File::Spec->catdir($openmw_root, 'outside');
	make_path($outside);
	my $automatic = run_tes3cmd_with_env($outside, \%environment, 'active');
	is($automatic->{exit}, 0, 'the default OpenMW configuration is discovered');
	like($automatic->{stdout}, qr/First\.esm\nSecond\.esp/, 'automatic discovery reads OpenMW content');

	my $classic = File::Spec->catdir($openmw_root, 'classic');
	my $classic_data = File::Spec->catdir($classic, 'Data Files');
	my $nested = File::Spec->catdir($classic, 'tools', 'work');
	make_path($classic_data, $nested);
	write_plugin_value(File::Spec->catfile($classic_data, 'Classic.esp'), 9);
	write_text(
		File::Spec->catfile($classic, 'Morrowind.ini'),
		"[Game Files]\nGameFile0=Classic.esp\n",
	);
	my $nearby = run_tes3cmd_with_env($nested, \%environment, 'active');
	is($nearby->{exit}, 0, 'nearby classic discovery succeeds');
	like($nearby->{stdout}, qr/Classic\.esp/, 'nearby classic installation takes precedence');
	unlike($nearby->{stdout}, qr/First\.esm/, 'the default OpenMW content is not mixed in');
};

done_testing;
