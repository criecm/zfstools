#!/bin/sh
#
exiterror() {
  echo $@
  exit 1
}

usage() {
  exiterror "usage: $0 zfs sourcehost"
}

[ $# -eq 2 ] || usage
zfs=$1
sourcehost=$2

there() {
  echo "ssh -x $sourcehost $@" >&2
  ssh -x "$sourcehost" "$@"
}
here() {
  echo "$@" >&2
  eval "$@"
}

[ "$(zfs get -Hp readonly "$zfs" | cut -w -f3)" = "on" ] || exiterror "$zfs not readonly here (not destination ?)"

TMPDIR=/tmp/$$
mkdir -p $TMPDIR
LISTSRC="${TMPDIR}/src.$$"
LISTDST="${TMPDIR}/dst.$$"
snaphead="${sourcehost%.*}-$(hostname -s)"

echo "disable cron"
crontab -l | sed 's@^\([0-9].*sync_zfs_pra_from.sh .* '$zfs'\)$@#\1@' | crontab -

there "zfs list -H -oname -t snapshot -s creation -r '$zfs'" > "$LISTSRC" || exiterror "unable to list source snapshots"
zfs list -H -oname -t snapshot -s creation -r "$zfs" > $LISTDST || exiterror "unable to list dest snapshots"

errcount=0
lastsrcsnap=$(there zfs list -Honame -t snapshot -s creation -r -d1 "$zfs" | grep @${snaphead} | tail -1 | sed 's/^.*@//')
lastvalidsnap=$(there zfs get -Hovalue lastpra:$(hostname -s) "$zfs")
# suppression des snapshots de synchro intermediaires inutiles
there "zfs list -Honame -tsnapshot -r -d1 $zfs | grep '^$zfs@$snaphead' | egrep -v '($lastsrcsnap|$lastvalidsnap)' | xargs -t -L1 zfs destroy -rd"
for fs in $(sed 's/@.*//' "$LISTSRC" | grep -v "${zfs}$" | sort -u); do
  lasthere=$(grep "^$(fgrep $fs@${snaphead} "$LISTDST" | tail -1)$" "$LISTSRC")
  if [ -z "${lasthere}" ]; then
    lasthere=""
    for snap in $(grep "^$fs@" "$LISTDST"); do
      grep -q "^${snap}$" "$LISTSRC" && lasthere=${snap}
    done
  fi
  [ -n "$lasthere" ] && here zfs rollback -r "$lasthere"
  lastthere=$(fgrep $fs@$lastsrcsnap "$LISTSRC" | tail -1)
  [ -z "$lastthere" ] && continue
  if [ "$lasthere" != "$lastthere" ]; then
    there zfs send -R ${lasthere:+"-I${lasthere#$fs}"} "$lastthere" | here "mbuffer -q | zfs receive -vF $fs" || errcount=$(( errcount + 1 ))
  fi
done
if [ $errcount -eq 0 ]; then
  lastdst=$(zfs list -Honame -t snapshot -s creation -r -d1 "$zfs" | tail -1)
  there "zfs list -r -d1 -t snapshot -Honame $zfs" > "$LISTSRC"
  if ! grep -q "^${lastdst}$" "$LISTSRC"; then
    for snap in $(zfs list -Honame -t snapshot -s creation -r -d1 "$zfs" | fgrep $zfs); do
      grep -q "^${snap}$" "$LISTSRC" && lastdst=${snap}
    done
    [ -n "$lastdst" ] && here zfs rollback "$lastdst"
  fi
  lastsrc=$(there zfs list -Honame -t snapshot -s creation "$zfs@$lastsrcsnap")
  # suppression des snapshots de synchro intermediaires inutiles
  there "zfs list -Honame -tsnapshot -r -d1 $zfs | grep '^$zfs@$snaphead' | egrep -v '($lastsrc|$lastdst|$lastvalidsnap)' | xargs -t -L1 zfs destroy -d"
  if [ "$lastsrc" != "$lastdst" ]; then
    there zfs send -I"${lastdst#$zfs}" "$lastsrc" | here "mbuffer -q | zfs receive -vF $zfs" || exiterror "PB a la synchro finale"
  fi 
  there "zfs set lastpra:$(hostname -s)=${lastsrcsnap} $zfs"

  echo "re-enable cron"
  crontab -l | sed 's@^#\([0-9].*sync_zfs_pra_from.sh .* '$zfs'\)$@\1@' | crontab -

fi
rm -rf "$TMPDIR"

