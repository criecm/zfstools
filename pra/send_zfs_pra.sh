#!/bin/sh -e
#
# script d'envoi de zfs "Flow"
# DOIT être déclenché par une "command" de cle ssh
#
# arguments (dans $SSH_ORIGINAL_COMMAND):
#    dsthost srcvol [send|list|received]
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

trace="/var/db/zfs_sent_$(echo "$zfs_fs" | sed 's/\//_/g')-${to}"
from="$(hostname -s)"

case "$command" in
  received)
    now=$(cat "$trace")
    if [ -z "$now" ]; then
      echo "$trace does not exists" >&2
      exit 1
    fi
    last=$(zfs get -Hovalue lastpra:$to "$zfs_fs")
    if ! [ "$last" = "-" ]; then
      logger -p local4.info "zfs destroy -r ${zfs_fs}@${last}"
      zfs destroy -r "${zfs_fs}@${last}"
    fi
    logger -p local4.info "zfs set lastpra:${to}=${from}-${to}-${now} $zfs_fs"
    zfs set "lastpra:$to"="$from-$to-$now" "$zfs_fs"
    echo "${from}-${to}-${now}"
    rm "$trace"
    # menage
    if [ "$(date +%u)" -eq 0 ] && [ "$(date +%H)" -lt 2 ]; then
      for snap in $(zfs list -r -Honame -t snapshot -d 1 "$zfs_fs" | grep "${zfs_fs}@${from}-${to}-" | grep -v "${zfs_fs}@${from}-${to}-${now}"); do
        logger -p local4.info "zfs destroy -r $snap (menage)"
        zfs destroy -rd "$snap"
      done
      if [ "$(zfs get -s local -H -ovalue lastbackup:$to $zfs_fs)" != "-" ]; then
        logger -p local4.info "zfs inherit lastbackup:$to $zfs_fs (menage)"
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
    logger -p local4.warn "failed: zfs destroy -r ${zfs_fs}@${from}-${to}-${now}"
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
    logger -p local4.info "zfs snapshot $zfs_fs@$from-$to-$now"
    zfs snapshot -r "$zfs_fs@$from-$to-$now"
    lastsnap=$(zfs get -H -ovalue "lastpra:$to" "$zfs_fs" 2>/dev/null)
    if [ "$lastsnap" = "-" ]; then
      # au cas ou on avait une synchro avant
      lastsnap=$(zfs get -H -ovalue "lastbackup:$to" "$zfs_fs" 2>/dev/null)
    fi
    if ! [ "$lastsnap" = "-" ]; then
      # si on a un last, on l'utilise
      logger -p local4.info "zfs send -RI @${lastsnap} ${zfs_fs}@${from}-${to}-${now}"
      zfs send -RI "@${lastsnap}" "${zfs_fs}@${from}-${to}-${now}"
    else
      # sinon on envoie tout
      logger -p local4.info "zfs send ${zfs_fs}@${from}-${to}-${now}"
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

