#!/usr/bin/perl
# Block hosts trying to break in using SSH
# SSHBlock v1.0
# 2006-12-03, anders@bsdconsulting.no
#
# Purpose:
#
# SSHBlock is a daemon to monitor a syslog log for break-in attempts using
# SSH, and to automatically block bad hosts by adding lines to
# /etc/hosts.allow (TCP Wrappers). Several thresholds are pre-defined, to be
# able to block those trying many attempts within a longer or shorter period.
#
# Use -h to see options
#
# History:
#
# 1.0 Initial release
#
# Copyright (c) 2006, Anders Nordby <anders@bsdconsulting.no>
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
# * Redistributions of source code must retain the above copyright notice, this
# list of conditions and the following disclaimer.
# 
# * Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
# 
# * Neither the name of BSD Consulting nor the names of its contributors may
# be used to endorse or promote products derived from this software without
# specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

package SSHBlock;
use File::Tail;
use Getopt::Std;
use FindBin qw($Bin);
use POSIX;
use strict;

getopts('hb:l:t:');
use vars qw { $line @entries $opt_h $opt_b $opt_l $opt_t };

# --- default configuration ---
if (!$opt_b) { $SSHBlock::blockfile = "/etc/hosts.allow"; }
if (!$opt_l) { $SSHBlock::logfile="/var/log/auth.log"; }

# How many lines to read initially from log:
$SSHBlock::lines = 0;   
# How many lines to read initially from log if rotated:
$SSHBlock::resetlines = -1;
# How often to check log (should check every second):
$SSHBlock::interval = 1;
# --- end configuration ---

# Which text lines to treat as a break-in attempt
# NB, must cache the host/IP with () in the expression:
%SSHBlock::badlines = (
	' sshd\[\d+\]: Invalid user .+ from (.+)', 1,
	' sshd\[\d+\]: error: PAM: authentication error for .+ from (.+)', 1,
);
# How often to delete old hosts from memory:
$SSHBlock::cleanuptime = 360;
# Must cache the host/IP with () in the expression:
if ($opt_t) {
	# Parse thresholds from command line
	my $thold;
	my $tholdsecs;
	my $tholdtries;
	foreach $thold (split(" ", $opt_t)) {
		($tholdsecs,$tholdtries) = split(":", $thold);
		$SSHBlock::thresholds{$tholdsecs} = $tholdtries;
	}
} else {
	%SSHBlock::thresholds = (
#	 5 attempts in 15 seconds
		15 => 5,
#	 10 attempts in 60 seconds
		60 => 10,
#	 20 attempts in one hour
		3600 => 20,
#	 30 attempts in one day
		86400 => 30
	);
}
%SSHBlock::badhosts = ();

sub isattempt {
	# $_[0]: str
	my $ckstr;

	foreach $ckstr (keys %SSHBlock::badlines) {
		if ($_[0] =~ /$ckstr/) {
			return $1;
		}
	}
	return "";
}

sub cleanup {
	my $host;
	my $thold;
	my $htime;
	my $time = int(time);
	my $maxtime;
	my $maxthold;
	my $eref;

	# Find the longest threshold value
	$maxthold = 0;
	foreach $thold (keys %SSHBlock::thresholds) {
		if ($thold > $maxthold) {
			$maxthold = $thold;
		}
	}

	# Check if the host is an expired entry
	foreach $host (keys %SSHBlock::badhosts) {
		# Get the reference to the hosts entries array
		$eref = $SSHBlock::badhosts{"$host"};

		# Find the latest attempt
		$maxtime = 0;
		foreach $htime (@{$eref}) {
			if ($htime > $maxtime) {
				$maxtime = $htime;
			}
		}

		# Check if the latest attempt is expired
		# If so, delete the entries for this host in the hash
		if (($time-$maxtime) > $maxthold) {
			delete($SSHBlock::badhosts{"$host"});
		}
	}
}

sub blockhost {
	# $_[0]: hostname $_[1]: threshold $_[2]: attempts
	my $host = $_[0];
	my $thold = $_[1];
	my $attempts = $_[2];
	open(ACCESS, ">>$SSHBlock::blockfile");
	print ACCESS "# Added by SSHBlock [" . scalar localtime(time) . "]\n";
	print ACCESS "# $attempts break-in attempts in $thold seconds:\n";
	print ACCESS "sshd : $host : deny\n";
	close(ACCESS);
}

sub ckhost {
	# $_[0]: hostname
	my $host = $_[0];
	my $time = int(time);
	my $htime;
	my $thold;
	my $eref;
	my $badnum;

	# Add the time to the hosts hash
	if (exists $SSHBlock::badhosts{"$host"}) {
		# Get the reference to the hosts entries array
		$eref = $SSHBlock::badhosts{"$host"};
		# Add entry
		push(@{$eref}, $time);
	} else {
		# Make array
		@entries = ($time);
		$SSHBlock::badhosts{"$host"} = \@entries;
	}

	# Check if the host is within thresholds
	foreach $thold (keys %SSHBlock::thresholds) {
		# Get the reference to the hosts entries array
		$eref = $SSHBlock::badhosts{"$host"};
		# Number of bad entries for this threshold is 0
		$badnum = 0;

		# Add up entries if they are within the current threshold
		foreach $htime (@{$eref}) {
			if (($time-$htime) <= $thold) {
				$badnum++;
			}
		}

		# Check if the number of entries is beyond the limit for this
		# threshold. Block the host if so, and delete the entries for
		# this host in the hash.
		if ($badnum >= $SSHBlock::thresholds{$thold}) {
			blockhost($host, $thold, $badnum);
			delete($SSHBlock::badhosts{"$host"});
		}
	}
}

sub usage {
	print "Usage: sshblock [ -b <blockfile> ] [ -l <logfile> ] [ -t <trigger list> ]\n";
	print "\n";
	print "Trigger list is a list of seconds:attempts threshold pairs for determining\n";
	print "whether a host should be blocked\n";
	print "\n";
	print "Default blockfile: /etc/hosts.allow\n";
	print "Default logfile: /var/log/auth.log\n";
}

if ($opt_h) {
	usage;
	exit(0);
}

# Set process name
#$0='sshblock';

# Fork, and detach to background
exit 0 if (fork);
chdir($Bin);
close(STDERR);
close(STDOUT);
close(STDIN);
POSIX::setsid;

# Set up cleanup alarm
$SIG{ALRM} = sub { cleanup; alarm($SSHBlock::cleanuptime); };
alarm($SSHBlock::cleanuptime);

my $badhost;

$SSHBlock::logfile = File::Tail->new(name=>$SSHBlock::logfile, maxinterval=>$SSHBlock::interval, interval=>$SSHBlock::interval, tail=>$SSHBlock::lines, reset_tail=>$SSHBlock::resetlines, errmode=>"return", ignore_nonexistant=>1);

while(defined($line=$SSHBlock::logfile->read)) {
	chomp($line);
	$badhost = isattempt($line);
	if ($badhost) {
		ckhost($badhost);
	}
}
