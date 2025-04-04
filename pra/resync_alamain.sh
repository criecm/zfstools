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
errwith=""
lastsrcsnap=$(there zfs list -Honame -t snapshot -s creation -r -d1 "$zfs" | grep @${snaphead} | tail -1 | sed 's/^.*@//')
lastvalidsnap=$(there zfs get -Hovalue lastpra:$(hostname -s) "$zfs")
for fs in $(sed 's/@.*//' "$LISTSRC" | grep -v "${zfs}$" | sort -u); do
  lastdsthere=$(grep "^$fs@${snaphead}" "$LISTDST" | tail -1)
  if [ -n "${lastdsthere}" ]; then
    lasthere=$(grep "^$lastdsthere$" "$LISTSRC")
  else
    lasthere=""
  fi
  if [ -z "${lasthere}" ]; then
    for snap in $(grep "^$fs@" "$LISTDST"); do
      grep -q "^${snap}$" "$LISTSRC" && lasthere=${snap}
    done
    [ -z "${lasthere}" ] && echo "no sync snap for $fs"
  fi
  [ -n "$lasthere" ] && [ "$(grep "^$fs@" "$LISTDST" | tail -1)" != "$lasthere" ] && here zfs rollback -r "$lasthere"
  lastthere=$(fgrep $fs@$lastsrcsnap "$LISTSRC" | tail -1)
  [ -z "$lastthere" ] && continue
  if [ -n "$lasthere" ] && [ "$lasthere" != "$lastthere" ]; then
    # suppression des snapshots de synchro intermediaires inutiles avant synchro
    there "zfs list -Honame -tsnapshot -r -d1 $fs | grep '$fs@$snaphead' | egrep -v '($lasthere|$lastthere)' | xargs -L1 zfs destroy -d"
    if ! there zfs send -R ${lasthere:+"-I${lasthere#$fs}"} "$lastthere" | here "mbuffer -q | zfs receive -vF $fs"; then
      errcount=$(( errcount + 1 ))
      errwith="$fs\n$errwith"
    fi
  fi
done
if [ $errcount -eq 0 ]; then
  lastdst=$(zfs list -Honame -t snapshot -s creation -r -d1 "$zfs" | grep @${snaphead} | tail -1)
  there "zfs list -r -d1 -t snapshot -Honame $zfs" > "$LISTSRC"
  if ! grep -q "^${lastdst}$" "$LISTSRC"; then
    for snap in $(zfs list -Honame -t snapshot -s creation -r -d1 "$zfs" | fgrep $zfs); do
      grep -q "^${snap}$" "$LISTSRC" && lastdst=${snap}
    done
    [ -n "$lastdst" ] && here zfs rollback "$lastdst"
  fi
  lastsrc=$(grep "^$zfs@$lastsrcsnap$" "$LISTSRC")
  if [ -z "$lastsrc" ]; then
    for snap in $(zfs list -Honame -tsnap -s creation $zfs | sed 's/^.*@//'); do
      grep -q "^$zfs@$snap$" "$LISTSRC" && lastsrc=$zfs@$snap && break
    done
  fi
  if [ -z "$lastsrc" ]; then
    echo "Erreur avec $zfs: pas de snapshot pour la synchro :/" >&2
    exit 1
  fi
  # suppression des snapshots de synchro intermediaires inutiles
  there "zfs list -Honame -tsnapshot -r -d1 $zfs | grep '^$zfs@$snaphead' | egrep -v '($lastsrc|$lastdst|$lastvalidsnap)' | xargs -t -L1 zfs destroy -d"
  if zfs list $zfs@${lastsrc#*@} > /dev/null 2>&1; then
    zfs rollback -r $zfs@${lastsrc#*@}
  elif [ "$lastsrc" != "$lastdst" ]; then
    there zfs send -I"${lastdst#$zfs}" "$lastsrc" | here "mbuffer -q | zfs receive -vF $zfs" || exiterror "PB a la synchro finale"
  fi 
  lastsrcsnap=${lastsrc#$zfs@}
  lastsnaptime=${lastsrcsnap##*-}
  there "zfs set lastpra:$(hostname -s)=${lastsrc#$zfs@} $zfs && echo $lastsnaptime > zfs_sent_$(echo $zfs | sed 's@/@_@g')-$(hostname -s)"

  echo "re-enable cron"
  crontab -l | sed 's@^#\([0-9].*sync_zfs_pra_from.sh .* '$zfs'\)$@\1@' | crontab -

else
  echo "$errcount ERREURS"
  echo "$errwith"
fi
rm -rf "$TMPDIR"

