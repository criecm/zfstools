#!/bin/sh
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
  MYTMPDIR=${TMPDIR:-/var/tmp}/sync_zfs
  mkdir -p -m 700 $MYTMPDIR
  export SSHKEY SRC DST LOGNAME KEEPEXPR MYTMPDIR
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
  ssh -oIdentitiesOnly=yes -oBatchMode=yes -ax -oControlMaster=auto -oControlPath=$MYTMPDIR/%h%p%r -oControlPersist=yes -i $SSHKEY $SRCHOST $*
}

exit_on_error() {
  echo $* >&2
  echo "$(date): $*" >> /var/log/$LOGNAME.log
  tail /var/log/$LOGNAME.log >&2
  tail /var/log/$LOGNAME.log | mail -s "Erreur $0 $*" root
  exit 1
}

logue_error() {
  echo $* >&2
  echo "ERROR $(date): $*" >> /var/log/$LOGNAME.log
  tail /var/log/$LOGNAME.log >&2
}

if [ -x "/root/sync_zfs_actions.$(echo $DSTVOL | sed 's@/@_@g').sh" ]; then
    /root/sync_zfs_actions.$(echo $DSTVOL | sed 's@/@_@g').sh before
fi

srcname=$(do_on_srchost $DSTHOST connect | cut -d' ' -f2)

NBERRS=0
NBVOLS=0
for SVOL in $(do_on_srchost $DSTHOST $SRCVOL list); do
  NBVOLS=$(( NBVOLS + 1 ))
#do_on_srchost $DSTHOST $SRCVOL list | while read SVOL SOPTS; do
  errs=0
  SUBZFS=${SVOL#$SRCVOL}
  SRCZFS=$SVOL
  SUBZFS=${SUBZFS#/}
  DSTZFS=$DSTVOL${SUBZFS:+/$SUBZFS}
  SOPTS=""
  echo "$(date): $SRCHOST:$SRCZFS -> $DSTZFS" >> /var/log/$LOGNAME.log
  if ! zfs list -Honame $DSTZFS > /dev/null 2>&1; then
    echo "$(date): zfs create $DSTZFS" >> /var/log/$LOGNAME.log
    zfs create -o readonly=on $DSTZFS
    do_on_srchost $DSTHOST $SRCZFS props | while read p v; do
      echo "zfs set $p=\"$v\" $DSTZFS" >> /var/log/$LOGNAME.log
      zfs set $p="$v" $DSTZFS
    done
    do_on_srchost $DSTHOST $SRCZFS destroy_bookmark >> /var/log/$LOGNAME.log 2>&1 || exit_on_error 
    if ! do_on_srchost $DSTHOST $SRCZFS send | zfs receive -F $DSTZFS >> /var/log/$LOGNAME.log 2>&1; then
      logue_error "ERREUR lors de do_on_srchost $DSTHOST $SRCZFS send | zfs receive -F $DSTZFS"
      errs=$(( errs + 1 ))
    fi
  else
    ( do_on_srchost $DSTHOST $SRCZFS props; echo "readonly	on" ) | while read p v; do
      localprop=$(zfs get -H -p -s local,received -o value $p $DSTZFS)
      if ! [ "$localprop" = "$v" ]; then
        echo "zfs set $p=\"$v\" $DSTZFS" >> /var/log/$LOGNAME.log
        zfs set $p="$v" $DSTZFS
      fi
    done
    if ! do_on_srchost $DSTHOST $SRCZFS send | zfs receive $DSTZFS >> /var/log/$LOGNAME.log 2>&1; then
      if ! do_on_srchost $DSTHOST $SRCZFS send | zfs receive -F $DSTZFS >> /var/log/$LOGNAME.log 2>&1; then
        logue_error "ERREUR lors de do_on_srchost $DSTHOST $SRCZFS send | zfs receive -F $DSTZFS"
        errs=$(( errs + 1 ))
      fi
    fi
  fi
  if [ $errs == 0 ]; then
    last=$(do_on_srchost $DSTHOST $SRCZFS received)
    echo "$(date): $SRCHOST:$SRCZFS@$last received" >> /var/log/$LOGNAME.log
    if [ -n "$last" ]; then
      zfs list -Honame -t snapshot -r -d1 $DSTZFS | egrep '@'${srcname}'-'$DSTHOST'-[0-9]{10}' | grep -v '@'$last | xargs -L1 zfs destroy -d
    fi
  else
    logue_error "$SRCZFS NOT received, snapshots kept"
    NBERRS=$(( NBERRS + 1 ))
  fi
done

if [ $NBERRS -eq $NBVOLS ] && [ $NBERRS -gt 0 ]; then
  logue_error "$NBERRS erreurs pour $NBVOLS filesystems/volumes"
  tail /var/log/$LOGNAME.log | mail -s "$0 on $(hostname -s): $NBERRS erreurs pour $NBVOLS filesystems/volumes" root
  exit $NBERRS;
fi

ssh -oIdentitiesOnly=yes -oBatchMode=yes -ax -oControlMaster=auto -oControlPath=$MYTMPDIR/%h%p%r -oControlPersist=yes -O exit -i $SSHKEY $SRCHOST 2>/dev/null

# snapshot dest
[ ! -z "$KEEPEXPR" ] && $SNAPSCRIPT -r -c $KEEPEXPR $DSTVOL >> /var/log/$LOGNAME.log

if [ -x "/root/sync_zfs_actions.$(echo $DSTVOL | sed 's@/@_@g').sh" ]; then
    /root/sync_zfs_actions.$(echo $DSTVOL | sed 's@/@_@g').sh after
fi
