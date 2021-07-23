#!/bin/sh -e
#
# needs sync_to.sh script installed as SSH forced command on src host
#
# usage: $0 ~/.ssh/id_... srchost:zfs_src_vol zfs_dst_vol [KEEPEXPR]
#
unset SSH_AUTH_SOCK
export LANG=C

if [ "$LOCKED_SYNC_JAILS" != "YES_LOCKED" ]; then
  export LOCKED_SYNC_JAILS="YES_LOCKED"
  SSHKEY=$1
  SRC=$2
  DST=$3
  KEEPEXPR=""
  if [ $# -eq 4 ]; then
    KEEPEXPR=$4
  fi
  LOGNAME=sync_$(echo $DST | sed 's/[^-a-zA-Z0-9_]/_/g;')
  export SSHKEY SRC DST LOGNAME KEEPEXPR
  echo "$(date): lock $0 $*" >> /var/log/$LOGNAME.log
  exec lockf -t 0 /var/run/$LOGNAME.lock $0
fi

SRCHOST=${SRC%%:*}
SRCVOL=${SRC#*:}
DSTHOST=${DST%%:*}
[ "$DSTHOST" = "$DST" ] && DSTHOST=$(hostname -s)
DSTVOL=${DST#*:}

if [ -n "$KEEPEXPR" ]; then
  SNAPSCRIPT=${SNAPSCRIPT:-$(realpath $(dirname $0))/../zfs_snap_make}
  [ -x "$SNAPSCRIPT" ] || exit_on_error "Snapscript $SNAPSCRIPT introuvable"
fi

do_on_srchost() {
  ssh -oIdentitiesOnly=yes -oBatchMode=yes -axi $SSHKEY $SRCHOST $*
}

exit_on_error() {
  echo $* >&2
  echo "$(date): $*" >> /var/log/$LOGNAME.log
  tail /var/log/$LOGNAME.log >&2
  tail /var/log/$LOGNAME.log | mail -s "Erreur $0 $*" root
  exit 1
}

for SUBZFS in '' $(do_on_srchost $DSTHOST $SRCVOL list | sed 's@^'$SRCVOL'@@'); do
  SRCSUBVOL=$SRCVOL${SUBZFS:+/$SUBZFS}
  DSTSUBVOL=$DSTVOL${SUBZFS:+/$SUBZFS}
  echo "$(date): $SRCHOST:$SRCSUBVOL -> $DSTSUBVOL" >> /var/log/$LOGNAME.log
  do_on_srchost $DSTHOST $SRCSUBVOL send | zfs receive $DSTSUBVOL >> /var/log/$LOGNAME.log 2>&1 ||
    do_on_srchost $DSTHOST $SRCSUBVOL send | zfs receive -F $DSTSUBVOL >> /var/log/$LOGNAME.log 2>&1 || exit_on_error
  last=$(do_on_srchost $DSTHOST $SRCSUBVOL received)
  echo "$(date): $SRCHOST:$SRCSUBVOL@$last received" >> /var/log/$LOGNAME.log
  if [ -n "$last" ]; then
    zfs list -Honame -t snapshot -r -d1 $DSTSUBVOL | egrep '@'${SRCHOST%%.*}'-'$DSTHOST'-[0-9]{10}' | grep -v '@'$last | xargs -L1 zfs destroy -d
  fi
done

# snapshot dest
[ ! -z "$KEEPEXPR" ] && $SNAPSCRIPT -r -c $KEEPEXPR $DSTVOL >> /var/log/$LOGNAME.log
