#!/bin/sh -e
#
# script d'envoi de zfs "Flow"
# DOIT être déclenché par une "command" de cle ssh
#
# arguments (dans $SSH_ORIGINAL_COMMAND):
#    dsthost srcvol [health|send|last|received]
#    dsthost connect
#
if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
  to="${SSH_ORIGINAL_COMMAND%% *}"
  zfs_fs="${SSH_ORIGINAL_COMMAND#* }"
  command="${SSH_ORIGINAL_COMMAND##* }"
  if [ "$command" = "connect" ]; then
    echo "${SSH_CLIENT%% *} $(hostname -s) ok"
    exit 0
  fi
  if [ "$command" = "$zfs_fs" ]; then
    command="send"
  else
    zfs_fs="${zfs_fs% *}"
  fi
else
  echo "$0 work with \$SSH_ORIGINAL_COMMAND"
  exit 1
fi
[ -z "$to" ] || [ -z "$zfs_fs" ] && exit 1
zfs_fs="$(zfs list -Honame "$zfs_fs")"

[ -d /var/log/zfs_pra ] || mkdir -p -m 700 /var/log/zfs_pra
trace="/var/db/zfs_sent_$(echo "$zfs_fs" | sed 's/\//_/g')-${to}"
mylog="/var/log/zfs_pra/sent_$(echo "$zfs_fs" | sed 's/\//_/g')-${to}"
mypid=$$
from="$(hostname -s)"

logue() {
  echo "$(date) send_zfs_pra[${mypid}] $@" >> ${mylog}
}

logue "$SSH_ORIGINAL_COMMAND"

case "$command" in
  health)
    lasttrace=$(cat "$trace" 2>/dev/null || echo -n "")
    lastsync=$(zfs get -s local -H -ovalue lastbackup:$to $zfs_fs || echo "new")
    if [ -n "$lasttrace" ]; then
      if [ "${from}-${to}-${lasttrace}" = "${lastsync}" ]; then
        rm "${trace}"
      elif [ "${lastsync}" != "new" ]; then
        echo "trace ${lasttrace} differs from lastsync ${lastsync}"
        exit 1
      fi
    fi
    echo "$lastsync"
    exit 0
  ;;
  received)
    now=$(cat "$trace")
    if [ -z "$now" ]; then
      echo "$trace does not exists" >&2
      exit 1
    fi
    last=$(zfs get -Hovalue lastpra:$to "$zfs_fs")
    if ! [ "$last" = "-" ]; then
      logue "zfs destroy -r ${zfs_fs}@${last}"
      zfs destroy -r "${zfs_fs}@${last}"
    fi
    logue "zfs set lastpra:${to}=${from}-${to}-${now} $zfs_fs"
    zfs set "lastpra:$to"="$from-$to-$now" "$zfs_fs"
    echo "${from}-${to}-${now}"
    rm "$trace"
    # menage
    if [ "$(date +%u)" -eq 0 ] && [ "$(date +%H)" -lt 2 ]; then
      for snap in $(zfs list -r -Honame -t snapshot -d 1 "$zfs_fs" | grep "${zfs_fs}@${from}-${to}-" | grep -v "${zfs_fs}@${from}-${to}-${now}"); do
        logue "zfs destroy -r $snap (menage)"
        zfs destroy -rd "$snap" 2| tee -a ${mylog}
      done
      if [ "$(zfs get -s local -H -ovalue lastbackup:$to $zfs_fs)" != "-" ]; then
        logue "zfs inherit lastbackup:$to $zfs_fs (menage)"
        zfs inherit "lastbackup:${to}" "${zfs_fs}"
      fi
    fi
    exit 0
  ;;
  failed)
    now=$(cat "$trace")
    if [ -z "$now" ]; then
      echo "$trace does not exists" >&2
      exit 1
    fi
    last=$(zfs get -Hovalue lastpra:$to "$zfs_fs")
    logue "WARN: zfs destroy -r ${zfs_fs}@${from}-${to}-${now}"
    zfs destroy -r "${zfs_fs}@${from}-${to}-${now}"
    rm -f "$trace"
    echo "${last}"
    exit 0
  ;;
  last)
    if [ -f "$trace" ]; then
      echo "$from-$to-$(cat $trace)"
      exit 0
    else
      exit 1
    fi
  ;;
  send)
    zfs_fs=$(zfs list -Honame $zfs_fs)
    [ -n "$zfs_fs" ] || exit 1
    now=$(date +%s)
    logue "zfs snapshot $zfs_fs@$from-$to-$now"
    zfs snapshot -r "$zfs_fs@$from-$to-$now"
    lastsnap=$(zfs get -H -ovalue "lastpra:$to" "$zfs_fs" 2>/dev/null)
    if [ "$lastsnap" = "-" ]; then
      # au cas ou on avait une synchro avant
      lastsnap=$(zfs get -H -ovalue "lastbackup:$to" "$zfs_fs" 2>/dev/null)
    fi
    if ! [ "$lastsnap" = "-" ]; then
      # si on a un last, on l'utilise
      logue "zfs send -RI @${lastsnap} ${zfs_fs}@${from}-${to}-${now}"
      zfs send -RI "@${lastsnap}" "${zfs_fs}@${from}-${to}-${now}"
    else
      # sinon on envoie tout
      logue "zfs send ${zfs_fs}@${from}-${to}-${now}"
      zfs send -R "${zfs_fs}@${from}-${to}-${now}"
    fi
    echo "$now" > "$trace"
    exit 0
  ;;
  *)
    echo "$0 $*: invalid syntax"
    exit 1
  ;;
esac

