#! /usr/bin/perl -T
# control.pl 1.2 for LMon, anders@bsdconsulting.no, 2005-05-19
# External requirements: Config::IniFiles.
#
# Copyright (c) 2005, Anders Nordby <anders@bsdconsulting.no>
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

package LMon;
use Config::IniFiles;
use FindBin qw($Bin);
use Getopt::Std;
use POSIX;
use strict;
use IPC::Open3;

# --configuration ---
# How many lines to read initially from log:
$LMon::lines = 0;
# How many lines to read initially from log if rotated:
$LMon::resetlines = -1;
# For lines/resetlines, 0 = only read new lines, -1 = read everything.
# How long to wait before checking log buffer:
$LMon::waitsecs = 5;
# How long to wait before checking log buffer after a mail is sent:
$LMon::waitsecsnext = 3600;
# --- end configuration ---

$ENV{PATH} = "/sbin:/bin:/usr/sbin:/usr/bin";
$ENV{ENV} = "";

$LMon::gensect = "general";
$LMon::logvar = "log";
$LMon::rulevar = "rules";
$LMon::namevar = "name";
$LMon::modevar = "mode";
$LMon::sysnamevar = "sysname";
$LMon::buffervar = "buffer";
$LMon::fromvar = "from";
$LMon::tovar = "to";
$LMon::mailserversvar = "mailservers";
$LMon::cmdok = '([-\w\.\/\ \"\@\;\_]+)';
$LMon::fnok = '([-\w\.\_\/]+)';

$LMon::commname = "^perl";
$LMon::argcheck = "lmon\.pl";
$LMon::cfgfile = "$Bin/lmon.cfg";
$LMon::oscheck = '^(SunOS|Linux|FreeBSD)$';
$LMon::masterpid = $$;

use vars qw { $opt_i };

sub readconfig {
	if (! -f $LMon::cfgfile) {
		die("ERROR: Config file $LMon::cfgfile not found");
	} elsif (! -T $LMon::cfgfile) {
		die("ERROR: Config file $LMon::cfgfile is not a text file");
	} else {
		tie %LMon::cfg, 'Config::IniFiles', ( -file => $LMon::cfgfile );
	}
}

sub usage {
	print "Usage: lmon.pl [options] <keyword>\n\n";
	print "\tlist\t\t\tlist configured instances\n";
	print "\tstart\t\t\tstart all configured instances\n";
	print "\tstart -i <instance>\tstart given instances\n";
	print "\tstop\t\t\tstop all configured instances\n";
	print "\tstop -i <instance>\tstop given instances\n";
	print "\tstatus\t\t\tprint status for all configured instances\n";
	print "\tstatus -i <instance>\tprint status for given instance\n";
	exit(1);
}

sub pscmd {
	# $_[0]: cmd $_[1]: extra (optional)
	my $cmd = $_[0];
	my $extracmd = $_[1];
	if ($cmd =~ /^$LMon::cmdok$/) {
		$cmd = $1;
		$cmd .= " 2>/dev/null | tail +2";
		if ($extracmd) { $cmd .= " " . $extracmd; }
		return `$cmd`;
	} else {
		return "";
	}
}

sub instpid {
# Return instance pid, if it is running
# $_[0]: inst
	my $inst = $_[0];
	my $pidfile = $Bin . "/" . $inst . ".pid";
	my $username = getpwuid(getuid);

	if (! -T $pidfile) {
		# PID file missing or not a text file
		return 0;
	} else {
		open(PID, $pidfile);
		my $regpid = <PID>;
		close(PID);
		chomp($regpid);
		if (!int($regpid)) {
			return 0;
		} else {
			my $psuser;
			my $pspid;
			my $pscomm;
			my $psargs;
			for ((POSIX::uname)[0]) {
				/^(FreeBSD|Linux)$/	and do {
					$psuser = pscmd("ps -p $regpid -oruser");
					$psuser =~ s@\s+$@@g;
					$pspid = pscmd("ps -p $regpid -opid");
					$pspid =~ s@\s+$@@g;
					$pscomm = pscmd("ps -c -p $regpid -ocommand");
					$pscomm =~ s@\s+$@@g;
					$psargs = pscmd("ps -ww -p $regpid -ocommand");
					$psargs =~ s@\s+$@@g;
					next;
				};
				/^SunOS$/	and do {
					$psuser = pscmd("ps -p $regpid -oruser", "| awk '{print \$1}'");
					$pspid = pscmd("ps -p $regpid -opid");
					$pscomm = pscmd("ps -p $regpid -ocomm", "| xargs -n 1 basename");
					$psargs = pscmd("ps -p $regpid -oargs");
					next;
				};
			}
			chomp($psuser);
			chomp($pspid);
			chomp($pscomm);
			chomp($psargs);

			if (int($pspid) && $regpid == $pspid && $psuser eq "$username" && $pscomm =~ /$LMon::commname/ && $psargs =~ /$LMon::argcheck/ && $pspid != $LMon::masterpid) {
				return($regpid);
			} else {
				return(0);
			}
		}
	}
}

sub statusinst {
# $_[0]: instance name
	my $inst = $_[0];
	my $pid = instpid($inst);
	if ($pid) {
		print "$inst up, PID $pid.\n";
	} else {
		print "$inst down.\n";
	}
}

sub startinst {
# $_[0]: instance name
	my $inst = $_[0];

	print "Start lmon.pl instance $_[0]: ";
	if (!instpid($inst)) {
		# start instans

		# Check include mode
		if (exists $LMon::cfg{"$inst"}{"$LMon::modevar"} && $LMon::cfg{"$inst"}{"$LMon::modevar"} eq "include") {
			$LMon::includemode = 1;
		} elsif (exists $LMon::cfg{"$LMon::gensect"}{"$LMon::modevar"} && $LMon::cfg{"$LMon::gensect"}{"$LMon::modevar"} eq "include") {
			$LMon::includemode = 1;
		} else {
			$LMon::includemode = 0;
		}

		# Check system name
		if (exists $LMon::cfg{"$inst"}{"$LMon::sysnamevar"}) {
			$LMon::sysname = $LMon::cfg{"$inst"}{"$LMon::sysnamevar"};
		} elsif (exists $LMon::cfg{"$LMon::gensect"}{"$LMon::sysnamevar"}) {
			$LMon::sysname = $LMon::cfg{"$LMon::gensect"}{"$LMon::sysnamevar"};
		} else {
			$LMon::sysname = (POSIX::uname)[1];
		}

		# Check from address
		if (exists $LMon::cfg{"$inst"}{"$LMon::fromvar"}) {
			$LMon::from = $LMon::cfg{"$inst"}{"$LMon::fromvar"};
		} elsif (exists $LMon::cfg{"$LMon::gensect"}{"$LMon::fromvar"}) {
			$LMon::from = $LMon::cfg{"$LMon::gensect"}{"$LMon::fromvar"}
		} else {
			print "FAIL, no from address defined.\n"; return;
		}

		# Check to address
		if (exists $LMon::cfg{"$inst"}{"$LMon::tovar"}) {
			$LMon::recipients = $LMon::cfg{"$inst"}{"$LMon::tovar"};
		} elsif (exists $LMon::cfg{"$LMon::gensect"}{"$LMon::tovar"}) {
			$LMon::recipients = $LMon::cfg{"$LMon::gensect"}{"$LMon::tovar"}
		} else {
			print "FAIL, no to address defined.\n"; return;
		}

		# Check mail servers
		if (exists $LMon::cfg{"$inst"}{"$LMon::mailserversvar"}) {
			$LMon::mailservers = $LMon::cfg{"$inst"}{"$LMon::mailserversvar"};
		} elsif (exists $LMon::cfg{"$LMon::gensect"}{"$LMon::mailserversvar"}) {
			$LMon::mailservers = $LMon::cfg{"$LMon::gensect"}{"$LMon::mailserversvar"}
		} else {
			print "FAIL, no mail servers specified.\n"; return;
		}

		# Check max buffer lines
		if (exists $LMon::cfg{"$inst"}{"$LMon::buffervar"}) {
			$LMon::maxbuffer = $LMon::cfg{"$inst"}{"$LMon::buffervar"};
		} elsif (exists $LMon::cfg{"$LMon::gensect"}{"$LMon::buffervar"}) {
			$LMon::maxbuffer = $LMon::cfg{"$LMon::gensect"}{"$LMon::buffervar"};
		} else {
			$LMon::maxbuffer = 50;
		}

		if (exists $LMon::cfg{"$inst"}{"$LMon::namevar"}) {
			$LMon::logname = $LMon::cfg{"$inst"}{"$LMon::namevar"};
		} else {
			$LMon::logname = $LMon::cfg{"$inst"}{"$LMon::logvar"};
		}
	
##		print "OK?\n";
##		print "Include mode: $LMon::includemode\n";
##		print "System name: $LMon::sysname\n";

		if (!exists $LMon::cfg{"$inst"}{"$LMon::logvar"}) {
			print "FAIL, instance $inst needs configuration parameter " . $LMon::logvar . ".\n";
		} elsif (! -f $LMon::cfg{"$inst"}{"$LMon::logvar"}) {
			print "FAIL, log file " . $LMon::cfg{"$inst"}{"$LMon::logvar"} . " does not exist.\n";
		} elsif (! -f $LMon::cfg{"$inst"}{"$LMon::rulevar"}) {
			print "FAIL, rule file " . $LMon::cfg{"$inst"}{"$LMon::rulevar"} . " does not exist.\n";
		} elsif (! -T $LMon::cfg{"$inst"}{"$LMon::rulevar"}) {
			print "FAIL, rule file " . $LMon::cfg{"$inst"}{"$LMon::rulevar"} . " is not a text file.\n";
		} else {
			# Start lmon
		}

	} else {
		print "FAIL, already running.\n";
	}
}

sub xstartinst {
# $_[0]: instance name
	my $inst = $_[0];

	print "Start lmon.pl instance $_[0]: ";
	if (!instpid($inst)) {
		my $cmd = "cd $Bin; ./lmon.pl -r \"" . $LMon::cfg{"$inst"}{"$LMon::rulevar"} . "\" -f \"" . $LMon::cfg{"$inst"}{"$LMon::logvar"} . "\" -p \"" . $inst . ".pid\" -d";


		if (!exists $LMon::cfg{"$inst"}{"$LMon::logvar"}) {
			print "FAIL, instance $inst needs configuration parameter " . $LMon::logvar . ".\n";
		} elsif (! -f $LMon::cfg{"$inst"}{"$LMon::logvar"}) {
			print "FAIL, log file " . $LMon::cfg{"$inst"}{"$LMon::logvar"} . " does not exist.\n";
		} elsif (! -f $LMon::cfg{"$inst"}{"$LMon::rulevar"}) {
			print "FAIL, rule file " . $LMon::cfg{"$inst"}{"$LMon::rulevar"} . " does not exist.\n";
		} elsif (! -T $LMon::cfg{"$inst"}{"$LMon::rulevar"}) {
			print "FAIL, rule file " . $LMon::cfg{"$inst"}{"$LMon::rulevar"} . " is not a text file.\n";
		} else {
#			print "TRY: $cmd\n";

# untaint $cmd if characters are OK, sort-of
			if ($cmd =~ /^$LMon::cmdok$/) {
				$cmd = $1;

				local(*IN, *OUT, *ERR);
				my $mypid = open3(*IN, *OUT, *ERR, $cmd);
				close(IN);

				my $errdata;
				while (<ERR>) {
					$errdata .= $_;
				}
				close(ERR);
				close(OUT);
				waitpid($mypid, 0);
				my $ret = $?;

				if ($ret == 0) {
					print "OK.\n";
				} else {
					print "FAIL, startup problems:\n\n$errdata\n";
				}
			} else {
				my $badargs = $cmd;
				$badargs =~ s@$LMon::cmdok@@g;
				print "FAIL, invalid argument characters\nin command for instance $inst (see cmdok setting or disable\n-T option for Perl): $badargs.\n";
			}
		}
	} else {
		print "FAIL, already running.\n";
	}
}

sub stopinst {
# $_[0]: instance name
	my $inst = $_[0];

	print "Stop lmon.pl instance $_[0]: ";
	my $pid = instpid($inst);

	if (int($pid)) {
		if ($pid =~ /^(\d+)$/) {
			# untaint PID
			$pid = $1;

			kill 'TERM', $pid;
			my $pidfile = $inst . ".pid";
			if ($pidfile =~ /^$LMon::fnok$/) {
				# Untaint pidfile filename
				$pidfile = $1;
				if (-e $pidfile) { unlink($pidfile) };
			}
			print "DONE\n";
		} else {
			print "no valid PID number found.\n";
		}
	} else {
		print "not running.\n";
	}
}

sub fixconfig {
	my $inst;
	foreach $inst (keys %LMon::cfg) {
		next if ($inst =~ /^$LMon::gensect$/);

		# Fix the rule file filename/path
		if (!exists $LMon::cfg{"$inst"}{"$LMon::rulevar"}) {
			# No rule file specified, use default: <instance>.rules in $Bin
			$LMon::cfg{"$inst"}{"$LMon::rulevar"} = $Bin . "/" . $inst . ".rules";
		} elsif (! -f $LMon::cfg{"$inst"}{"$LMon::rulevar"}) {
			# Rule file not found, add $Bin before filename
			$LMon::cfg{"$inst"}{"$LMon::rulevar"} = $Bin . "/" . $LMon::cfg{"$inst"}{"$LMon::rulevar"};
		}
	}
}

sub ckpids {
	opendir(DIR, $Bin);
	my @dirfiles = readdir DIR;
	closedir(DIR);
	my $dirfile;
	foreach $dirfile (@dirfiles) {
		next if ($dirfile !~ /\.pid$/);
		my $inst = $dirfile;
		$inst =~ s@\.pid$@@;
		my $pidfile = $Bin . "/" . $dirfile;

		if (! -T $pidfile) {
			print "WARNING: PID file $dirfile found in program dir. Not even a valid text file!\n";
		} elsif (!exists $LMon::cfg{"$inst"}) {
			print "WARNING: PID file $dirfile found in program dir, but $inst is not in config.\n";
		} else {
			my $dirpid = $Bin . "/" . $dirfile;
			open(PID, $dirpid);
			my $regpid = <PID>;
			close(PID);
			if (!int($regpid)) {
				print "WARNING: PID file $dirfile found in program dir, but has no number.\n";
			} else {
				my $ckpid = instpid($inst);
				if ($ckpid && $ckpid != $regpid) {
					print "WARNING: PID file $dirfile found in program dir, but has unexpected PID.\n";
				}
			}
		}
	}
}

##########
##########
### XXX

#! /usr/bin/perl -T
# LMon 1.3, anders@bsdconsulting.no, 2005-05-19
# External requirements: Mail::Sendmail, File::Tail.
#
# History:
#
# 1.3:	Add / as allowed character in filename.
#	Send mail as bulk mail, to avoid bounces.

package LMon;
use Fcntl;
use Getopt::Std;
use POSIX;
use strict;
use Mail::Sendmail;
use File::Tail;
use FindBin qw($Bin);
$ENV{PATH} = "/sbin:/bin:/usr/sbin:/usr/bin";
$ENV{ENV} = "";

@LMon::reglist = ();
@LMon::logbuffer = ();
$LMon::logfile = ();
$LMon::logbuffertruncated = 0;
$LMon::fnok = '([-\w\.\_\/]+)';

use vars qw { $opt_f $opt_p $opt_r $opt_n $opt_s $opt_i $opt_t $opt_F $opt_b $opt_m $opt_d };

# Untaint $Bin if OK
if ($Bin =~ /$LMon::fnok/) {
	$Bin = $1;
}

sub usage {
	print "Usage: lmon.pl -r <rule file> -f <log file> [-t <recipients>] [-p <pid file>]\n";
	print "[-n <log name (for alerts)>] [-s <system name (for alerts)]\n";
	print "[-i (include mode: alert on rule hits instead of misses) [-F <from mailaddress>]\n";
	print "[-m <mail server(s)>] [-d (detach)]\n";
}
if ($#ARGV < 0) { usage; exit(0); }
getopts('r:f:t:p:n:s:F:b:im:d');
if ($opt_t) {
	$LMon::recipients = $opt_t;
}
if ($opt_b) {
	$LMon::maxbuffer = $opt_b;
}

my $line = "";

if ($opt_s) {
	$LMon::sysname = $opt_s;
} else {
	$LMon::sysname = (POSIX::uname)[1];
}
if (!$LMon::from) {
	$LMon::from = "hostmaster\@$LMon::sysname";
} elsif($opt_F) {
	$LMon::from = $opt_F;
}


if ($opt_i) {
	$LMon::alertstr = "LMon: interesting data in";
} else {
	$LMon::alertstr = "LMon: unrecognized data in";
}

if ($opt_m) {
	@LMon::mailserverstxt = split(/ /, $opt_m);
	$LMon::mailservers = \@LMon::mailserverstxt;
	for (my $i = 0; $i <= $#LMon::mailserverstxt; $i++) {
		if ($LMon::mailserverstxt[$i] =~ /^([\s\w\.-_]+)$/) {
			# untaint mailserver
			$LMon::mailserverstxt[$i] = $1;
		} else {
			print "Bad data $opt_m in option -m.\n";
			exit(1);
		}
	}
	$Mail::Sendmail::mailcfg{'smtp'} = \@LMon::mailserverstxt;
} else {
	$Mail::Sendmail::mailcfg{'smtp'} = $LMon::mailservers;
}

sub errusage {
	my $msg = $_[0];
	print "$msg\n\n";
	usage;
	exit(1);
}

sub sender {
	my $text = "$_[0]";
	my $subject = "$_[1]";

	for my $recipient (split /([ \s,;])/, $LMon::recipients) {
		my %mail = ( To      => "$recipient",
			     From    => "$LMon::from",
			     Message => "$text",
			     Subject => "$subject",
			     Precedence => "bulk"
		);

	sendmail(%mail);
	}
}

sub isinteresting {
	my $str = $_[0];
	chomp($str);
	my $substr;

	if ($opt_i) {
		for (my $i = 0; $i <= $#LMon::reglist; $i++) {
			if (substr($LMon::reglist[$i], 0, 1) eq '!') {
				$substr = substr($LMon::reglist[$i], 1);
				if ($str !~ /$substr/) { return(1); }
			} else {
				if ($str =~ /$LMon::reglist[$i]/) { return(1); }
			}
		}
		return(0);
	} else {
		for (my $i = 0; $i <= $#LMon::reglist; $i++) {
			if (substr($LMon::reglist[$i], 0, 1) eq '!') {
				$substr = substr($LMon::reglist[$i], 1);
				if ($str !~ /$substr/) { return(0); }
			} else {
				if ($str =~ /$LMon::reglist[$i]/) { return(0); }
			}
		}
		return(1);
	}
}

sub sendbuffer {
	if($LMon::logbuffertruncated != 0) {
		unshift(@LMon::logbuffer, "\n");
		unshift(@LMon::logbuffer, "from the top of the file.\n");
		unshift(@LMon::logbuffer, "ERROR: Log buffer got full at $LMon::maxbuffer lines. Data has been dropped\n");
		$LMon::logbuffertruncated = 0;
	}
	if ($opt_n) {
		sender(join("", @LMon::logbuffer), "$LMon::alertstr $opt_n on $LMon::sysname");
	} else {
		sender(join("", @LMon::logbuffer), "$LMon::alertstr $opt_f on $LMon::sysname");
	}
}

sub checkbuffer {
	if ($#LMon::logbuffer != -1) {
		sendbuffer;
		@LMon::logbuffer = ();
		alarm($LMon::waitsecsnext);
	} else {
		alarm($LMon::waitsecs);
	}
}

sub fixpidfilename {
	if ($opt_p =~ /^([-\w\.\/]+)$/) {
		# untaint PID filename
		$opt_p = $1;
	} else {
		print "Bad data $opt_p in option -p.\n";
		exit(1);
	}
}

sub writepid {
	fixpidfilename;
	if (sysopen(PID, $opt_p, O_WRONLY|O_CREAT)) {
		print PID "$$\n";
	} else {
		errusage("ERROR: Could not write pid file.");
	}
	close(PID);
}

sub readconf {
	sysopen(CONF, $opt_r, O_RDONLY);
	@LMon::reglist = ();
	my $line = 0;
	while (<CONF>) {
		my $rule = $_;
		$line++;

		next if ($rule =~ /^(#|$)/);
		chomp($rule);

		eval { if (/$rule/) {} };
		if ($@) {
			print STDERR "ABORT, syntax/regexp error on line $line in $opt_r.\n";
			print STDERR "Details:\n\n";
			print STDERR $@;
			close(CONF);
			exit(1);
		}

		push(@LMon::reglist, $rule);
	}
	close(CONF);
}

if (!$opt_f) {
	errusage("ERROR: No file to monitor specified, use -f.");
} elsif(! -f $opt_f) {
	errusage("ERROR: Logfile $opt_f does not exist/is not a file.");
}
if (!$opt_r) {
	errusage("ERROR: No rule file specified, use -r.");
} elsif(! -f $opt_r) {
	errusage("ERROR: Rule file $opt_r does not exist/is not a file.");
}
readconf;
if ($opt_d) {
	# Detach from controlling terminal
	exit 0 if (fork);
	chdir($Bin);
	close(STDERR);
	close(STDOUT);
	close(STDIN);
	POSIX::setsid;
}
writepid;

$SIG{ALRM} = sub { checkbuffer; };
alarm($LMon::waitsecs);

#$LMon::logfile = File::Tail->new($opt_f);
$LMon::logfile = File::Tail->new(name=>$opt_f, maxinterval=>30, interval=>10, tail=>$LMon::lines, reset_tail=>$LMon::resetlines, errmode=>"return");

while(defined($line=$LMon::logfile->read)) {
	if (isinteresting($line)) {
		if (($#LMon::logbuffer+1) >= $LMon::maxbuffer && $LMon::maxbuffer != 0) {
			if ($LMon::logbuffertruncated == 0) {
				$LMon::logbuffertruncated = 1;
			}
			shift(@LMon::logbuffer);
			push(@LMon::logbuffer, $line);
		} else {
			push(@LMon::logbuffer, $line);
		}
	}
}


### YYY
##########
##########

if ($ARGV[0]) {
	if ($ARGV[0] =~ /^(start|stop|status)$/) {

		my $keyword = $ARGV[0];
		@ARGV = grep(!/^(start|stop|status)/, @ARGV);
		push(@ARGV, $keyword);
	}
} else {
	usage;
}

getopts('i:');
my $inst;

for ($ARGV[0]) {
	/^start$/	and do {
		readconfig; fixconfig;
		if ($opt_i) {
			if ($opt_i eq $LMon::gensect) {
				print "Could not start invalid instance $opt_i.\n";
			} elsif (exists $LMon::cfg{"$opt_i"}) {
				startinst($opt_i);
			} else {
				print "Could not start instance $opt_i, does not exist in configuration.\n";
			}
		} else {
			foreach $inst (keys %LMon::cfg) {
				next if ($inst =~ /^$LMon::gensect$/);
				startinst($inst);
			}
		}
		next;
	};
	/^stop$/	and do {
		readconfig;
		if ($opt_i) {
			if (exists $LMon::cfg{"$opt_i"}) {
				stopinst($opt_i);
			} else {
				print "Could not stop instance $opt_i, does not exist in configuration.\n";
			}
		} else {
			foreach $inst (keys %LMon::cfg) {
				next if ($inst =~ /^$LMon::gensect$/);
				stopinst($inst);
			}
		}
		next;
	};
	/^list$/	and do {
		readconfig;
		print "Instances:\n\n";
		foreach $inst (keys %LMon::cfg) {
			next if ($inst =~ /^$LMon::gensect$/);
			print "$inst\n";
		}
		next;
	};
	/^status$/	and do {
		readconfig;
		if ($opt_i) {
			if (exists $LMon::cfg{"$opt_i"}) {
				statusinst($opt_i);
			} else {
				print "Will not check status for instance $opt_i,\ndoes not exist in configuration.\n";
			}
		} else {
			foreach $inst (keys %LMon::cfg) {
				next if ($inst =~ /^$LMon::gensect$/);
				statusinst($inst);
			}
			ckpids;
		}
		ckpids;
		next;
	};
	usage;
}
