#! /usr/bin/perl
# simplemon 1.3
# script to monitor and alert on low diskspace situations & running processes
# Copyright 2003-07-05, anders@fix.no
#
# THIS SOFTWARE IS PROVIDED BY ANDERS NORDBY ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
# EVENT SHALL ANDERS NORDBY BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
# OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# History:
# 1.2: Separated script and config. Script now supports Solaris and FreeBSD.
#      Note: on Solaris, only 80 characters are searched in the process list
#      per process (this is a ps limitation in Solaris).
# 1.2a: Fixed typo.
# 1.3: Support for Linux. Tested in Debian 3.0r1.
# 1.3a: Ahem, do not exit when failing to send mail.</blush>

use Mail::Sendmail;
use Getopt::Std;
use FindBin qw($Bin);
use POSIX;
$ENV{'ENV'} = "";
$ENV{'PATH'} = "/sbin:/bin:/usr/sbin:/usr/bin";
getopts('c:');
if (!$opt_c) {
	$opt_c = "$Bin/simplemon.cfg";
}
require $opt_c;
$Mail::Sendmail::mailcfg{'smtp'} = $mailservers;

sub sender {
	my $text = "$_[0]";
	my $subject = "$_[1]";
	for my $recipient (split / /, $recipients) {
		my %mail = ( To      => "$recipient",
			     From    => "hostmaster\@$sysname",
			     Message => "$text",
			     Subject => "$subject"
			   );

		sendmail(%mail);
	}
}

sub fsfree {
	my $fs = $_[0];
	my $freekb = 0;
	for ((POSIX::uname)[0]) {
		/^(FreeBSD|SunOS|Linux)$/	and do {
			open(DF, "/bin/df -k $fs 2>/dev/null |");
			my @tmpoput = <DF>;
			$freekb = (split(' ', $tmpoput[1]))[3];
			if (!int($freekb)) {
				$freekb = 0;
			}
			close(DF);
			next;
		}
	}
	return $freekb;
}
# print fsfree($ckfs) . "\n";

sub checkfs {
	my $message = "";

	foreach $fsys (keys %myfilesystems) {
		my $spacefree = fsfree $fsys;
#		my $spacefree = (df $fsys)[3];
		if ($spacefree <= $myfilesystems{$fsys}) {
			$message .= "[$fsys] $spacefree kb (threshold $myfilesystems{$fsys}).\n";
		}
	}

	if ($message) {
		if ($debug) { print "Sending mail => \n\n$message\n\n"; }
		sender($message,"$sysname low diskspace alert");
		return 0;
	} else {
		return 1;
	}
}

sub pslister {
	my $separator = ";";
	my @output = ();
	my $pslist = "";
	for ((POSIX::uname)[0]) {
		/^(FreeBSD|Linux)$/	and do {
			if ($sloppyproc) {
				$pslist = "/bin/ps axww -oruid,rgid,command | tail +2 |";
			} else {
				$pslist = "/bin/ps axcww -oruid,rgid,command | tail +2 |";
			}
			next;
		};
		/^SunOS$/	and do {
			if ($sloppyproc) {
				$pslist = "/bin/ps -ef -oruid,rgid,args | tail +2 |";
			} else {
				$pslist = "/bin/ps -ef -oruid,rgid,comm | tail +2 |";
			}
			next;
		}
	}
	if ($pslist eq "") {
		return @output;
	}
	open(PSLIST, $pslist);
	while(<PSLIST>) {
		my @linje = split " ", $_;
		my $cmd = "";
		if ($sloppyproc) {
			for (my $i = 2; $i <= $#linje; $i++) {							$cmd = $cmd . " " . $linje[$i];
			}
			$cmd =~ s@^ @@;
		} else {
			$cmd = $linje[2];
		}
		push @output, { uid => $linje[0], gid => $linje[1], cmd => $cmd };
	}
	close(PSLIST);

	return @output;
}

sub checkproc {
	my $message = "";
	my $found = 0;
#	my $proctype = ($sloppyproc) ? "cmndline" : "fname";

	my @proclist = pslister();
	my $found = 0;
	foreach $cproc (keys %myprocesses) {
		$found = 0;

		for (my $p = 0; $p <= $#proclist; $p++) {
			if ($proclist[$p]{cmd} =~ /$cproc/ && $proclist[$p]{uid} == $myprocesses{$cproc}{uid} && $proclist[$p]{gid} == $myprocesses{$cproc}{gid}) {
				$found = 1;
				break;
			}
		}
		if (!$found) {
			$message .= "[$cproc:$myprocesses{$cproc}{uid}:$myprocesses{$cproc}{gid}] not running.\n";
		}
	}

	if ($message) {
		if ($debug) { print "Sending mail => \n\n$message\n\n"; }
		sender($message,"$sysname processes alert");
		return 0;
	} else {
		return 1;
	}
}

$sysname = (POSIX::uname)[1];
my $fswait = 0;
my $procwait = 0;

if ($daemon) {
	while() {
		if ($debug) { print "fswait = $fswait, procwait = $procwait\n"; }
		if ($fswait <= 0) {
			if (!checkfs) {
				$fswait = $fswait + $skiptime;
			}
		} else {
			$fswait = $fswait - $retryinterval;
		}
		if ($procwait <= 0) {
			if (!checkproc) {
				$procwait = $procwait + $skiptime;
			}
		} else {
			$procwait = $procwait - $retryinterval;
		}

		sleep($retryinterval);
	}
} else {
	checkfs;
	checkproc;
}
