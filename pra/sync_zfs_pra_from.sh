#!/bin/sh -e
#
# needs sync_to.sh script installed as SSH forced command on src host
#
# usage: $0 ~/.ssh/id_... srchost:zfs_src_vol zfs_dst_vol [KEEPEXPR]
#
unset SSH_AUTH_SOCK
export LANG=C
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

if [ "$LOCKED_SYNC_PRA" != "YES_LOCKED" ]; then
  export LOCKED_SYNC_PRA="YES_LOCKED"
  SSHKEY=$1
  SRC=$2
  DST=$3
  KEEPEXPR=""
  if [ $# -eq 4 ]; then
    KEEPEXPR=$4
  fi
  LOGNAME=sync_$(echo $DST | sed 's/[^-a-zA-Z0-9_]/_/g;')
  export SSHKEY SRC DST LOGNAME KEEPEXPR
  exec lockf -t 0 /var/run/$LOGNAME.lock $0
fi

SRCHOST=${SRC%%:*}
SRCVOL=${SRC#*:}
DSTHOST=${DST%%:*}
[ "$DSTHOST" = "$DST" ] && DSTHOST=$(hostname -s)
DSTVOL=${DST#*:}

[ -d /var/log/zfs_pra ] || mkdir -p -m 700 /var/log/zfs_pra

if [ -n "$KEEPEXPR" ]; then
  SNAPSCRIPT=${SNAPSCRIPT:-$(realpath $(dirname $0))/../zfs_snap_make}
  [ -x "$SNAPSCRIPT" ] || exit_on_error "Snapscript $SNAPSCRIPT introuvable"
fi

do_on_srchost() {
  ssh -oIdentitiesOnly=yes -oBatchMode=yes -axi $SSHKEY $SRCHOST $*
}

loggue() {
  echo "$(date) [$$] $*" > /var/log/zfs_pra/${LOGNAME}.log
}

exit_on_error() {
  echo $* >&2
  loggue $*
  tail /var/log/zfs_pra/${LOGNAME}.log >&2
  tail /var/log/zfs_pra/${LOGNAME}.log | mail -s "Erreur $0 $*" sysadm@ec-m.fr
  exit 1
}

srcname=$(do_on_srchost $DSTHOST $SRCVOL connect | cut -d' ' -f1)

SRCZFS=$SVOL
loggue "$SRCHOST:$SRCVOL -> $DSTVOL"
do_on_srchost $DSTHOST $SRCVOL send | mbuffer -q | zfs receive -F $DSTVOL >> /var/log/zfs_pra/${LOGNAME}.log 2>&1
endcode=$?
FAILED=""
if [ $endcode -gt 0 ]; then
  last=$(do_on_srchost $DSTHOST $SRCVOL last)
  [ -z "$last" ] && exit_on_error "pas de last ??? comprend rien"
  logue "$SRCHOST:$SRCVOL@$last returns $endcode : checking"
  for fs in $(zfs list -Honame -r $DSTVOL); do
    zfs list $fs@$last > /dev/null || FAILED="$fs $FAILED"
  done
  if [ -n "$FAILED" ]; then
    loggue "$SRCHOST:$SRCVOL@$last FAILED for"
    loggue "  $FAILED"
    LASTOK=$(do_on_srchost $DSTHOST $SRCVOL failed)
    if [ "$LASTOK" != "-" ]; then
      loggue "zfs rollback to $DSTVOL@$LASTOK"
      zfs rollback -r "$DSTVOL@$LASTOK" >> /var/log/zfs_pra/${LOGNAME}.log 2>&1
    fi
    exit_on_error "FAILED with @$last: $FAILED"
  fi
  loggue "$SRCHOST:$SRCVOL@$last returns $endcode : checked OK :)"
fi
received=$(do_on_srchost $DSTHOST $SRCVOL received)
loggue "$SRCHOST:$SRCVOL@$received received"
#if [ -n "$last" ]; then
#  zfs list -Honame -t snapshot -r -d1 $DSTVOL | egrep '@'${srcname}'-'$DSTHOST'-[0-9]{10}' | grep -v '@'$last | xargs -L1 zfs destroy -d
#fi

