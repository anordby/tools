#! /bin/bash
# Anders Nordby <anders@fupp.net>

# Options
# minimum number of errors before reporting:
minerrors=3
# report time, report after n seconds:
rtime=3600
#rtime=36
# lock stale time, remove lock after n seconds:
ltime=7000
#ltime=300
# Recipient for errors (optional)
#recipients="foouser@foodomain.com"

cd `dirname $0`
mydir=`pwd`
lck="$mydir/smbsync.lock"
err="$mydir/smbsync.err"
errc="$mydir/smbsync.errc"
logdir="$mydir/log"
errout="$mydir/smbsync.out"
out="$logdir/smbsync-`date +%Y-%m-%d`.log"

PATH="/usr/local/bin:$PATH"
export PATH
mytime=`perl -e "print time"`
case `uname -s` in
FreeBSD)
	errtime=`gstat -c "%Y" "$err" 2>/dev/null`
	;;
*)
	errtime=`stat -c "%Y" "$err" 2>/dev/null`
	;;
esac
errcount=`cat "$errc" 2>/dev/null`


if [ -z "$errtime" ]
then
	errtime=0
fi
if [ -z "$errcount" ]
then
	errcount=0
fi
errage="`echo $mytime-$errtime | bc | awk '{print $1}'`"

replockstuck() {
	for recip in $recipients
	do
		{
			echo "Lock $lck is really stuck. Deleting it. Next smbsync run will try again."
		} | mailx -s "smbsync errors on `hostname`" $recip
	done
}

replock() {
	# ventet lenge nok?
	if [ "$errage" -ge "$rtime" ]
	then
#		echo "DEBUG: waited long enough. errage=$errage rtime=$rtime" >>$out
		
		# feilet nok ganger?
		errcount=`echo $errcount + 1 | bc | awk '{print $1}'`
		if [ $errcount -ge $minerrors ]
		then
#			echo "DEBUG: failed enough times. errcount=$errcount" >>$out
			for recip in $recipients
			do
				{
				echo "Lock $lck is stuck. smbsync hangs?"
				} | mailx -s "smbsync errors on `hostname`" $recip
			done
			touch $err
			echo 0 >$errc
		else
#			echo "DEBUG: failed enough times? now: errcount=$errcount minerrors=$minerrors" >>$out
			echo $errcount >$errc
		fi
#	else
#		echo "DEBUG: waited long enough? errage=$errage rtime=$rtime" >>$out
	fi
}

repout() {
	if [ "$errage" -ge "$rtime" ]
	then
#		echo "DEBUG: waited long enough. errage=$errage rtime=$rtime" >>$out

		# feilet nok ganger?
		errcount=`echo $errcount + 1 | bc | awk '{print $1}'`
		if [ $errcount -ge $minerrors ]
		then
#			echo "DEBUG: failed enough times. errcount=$errcount" >>$out

			for recip in $recipients
			do
				{
				echo "Errors in smbsync operation on `hostname`:"
				echo
				tail -100 $out
				} | mailx -s "smbsync errors on `hostname`" $recip
			done
			touch $err
			echo 0 >$errc
		else
#			echo "DEBUG: failed enough times? now: errcount=$errcount minerrors=$minerrors" >>$out
			echo $errcount >$errc
		fi
#	else
#		echo "DEBUG: waited long enough? errage=$errage rtime=$rtime" >>$out
	fi
}

if (ln -s $lck $lck >/dev/null 2>&1)
then
	{
	echo "================================================================================"
	echo "Starting smbsync [`date`]"
	$mydir/smbsync
	} >>$out 2>$errout

	if [ -s $errout ]
	then
		repout
	fi
	rm $lck
else
	lcktime=`stat -c "%Y" "$lck" 2>/dev/null`
	if [ -z "$lcktime" ]
	then
		lcktime=0
	fi
	lckage="`echo $mytime-$lcktime | bc | awk '{print $1}'`"

	echo "Lock stuck $lckage seconds [`date`]" >>$out

	if [ "$lckage" -ge "$ltime" ]
	then
		echo "Removing lock [`date`]" >>$out
		rm $lck
		replockstuck
	else
		replock
	fi
fi

find $logdir -mtime +60 | xargs rm >/dev/null 2>&1
