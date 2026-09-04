package Tes3cmdTest;

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use Exporter qw(import);
use File::Basename qw(dirname);
use File::Spec;
use IPC::Run3 qw(run3);

our @EXPORT_OK = qw(
    read_binary
    run_command
    run_tes3cmd
    tes3cmd_path
    write_minimal_plugin
);

sub tes3cmd_path {
	my $root = dirname(dirname(dirname(abs_path(__FILE__))));
	return File::Spec->catfile($root, 'tes3cmd');
}

sub run_command {
	my ($cwd, @command) = @_;
	my ($stdout, $stderr) = ('', '');
	my $original_cwd = getcwd();
	my $error;
	my $raw_status;

	chdir($cwd) or die qq{Unable to enter test directory "$cwd": $!};
	eval {
		run3(\@command, \undef, \$stdout, \$stderr);
		$raw_status = $?;
		1;
	} or $error = $@;
	chdir($original_cwd)
		or die qq{Unable to restore working directory "$original_cwd": $!};
	die $error if defined($error);

	return {
		command    => \@command,
		exit       => $raw_status >> 8,
		raw_status => $raw_status,
		signal     => $raw_status & 127,
		stderr     => $stderr,
		stdout     => $stdout,
	};
}

sub run_tes3cmd {
	my ($cwd, @arguments) = @_;
	return run_command($cwd, $^X, tes3cmd_path(), @arguments);
}

sub _subrecord {
	my ($type, $data) = @_;
	die 'Subrecord type must contain exactly four bytes'
		unless length($type) == 4;
	return pack('a4V', $type, length($data)) . $data;
}

sub _record {
	my ($type, $flags, @subrecords) = @_;
	die 'Record type must contain exactly four bytes'
		unless length($type) == 4;
	my $payload = join('', @subrecords);
	return pack('a4VVV', $type, length($payload), 0, $flags) . $payload;
}

sub write_minimal_plugin {
	my ($path) = @_;

	my $hedr = pack(
		'f<VZ32Z256V',
		1.3,
		0,
		'tes3cmd tests',
		'generated fixture',
		1,
	);
	my $header = _record('TES3', 0, _subrecord('HEDR', $hedr));
	my $gmst = _record(
		'GMST',
		0,
		_subrecord('NAME', 'iTes3cmdTest'),
		_subrecord('INTV', pack('l<', 42)),
	);

	open(my $fh, '>', $path) or die qq{Unable to create fixture "$path": $!};
	binmode($fh, ':raw') or die qq{Unable to set binary mode on "$path": $!};
	print {$fh} $header, $gmst or die qq{Unable to write fixture "$path": $!};
	close($fh) or die qq{Unable to close fixture "$path": $!};

	return $path;
}

sub read_binary {
	my ($path) = @_;
	open(my $fh, '<', $path) or die qq{Unable to open "$path": $!};
	binmode($fh, ':raw') or die qq{Unable to set binary mode on "$path": $!};
	local $/;
	my $contents = <$fh>;
	close($fh) or die qq{Unable to close "$path": $!};
	return $contents;
}

1;
