#!/bin/sh -e
#
# script d'envoi de zfs "Flow"
# DOIT être déclenché par une "command" de cle ssh
#
# arguments (dans $SSH_ORIGINAL_COMMAND):
#    srchost dsthost srcvol [send|list|received]
#
env > /tmp/REMOTE_env
echo $0 >> /tmp/REMOTE_env
if [ -n "$SSH_ORIGINAL_COMMAND" ]; then
  to=${SSH_ORIGINAL_COMMAND%% *}
  zfs_fs=${SSH_ORIGINAL_COMMAND#* }
  command=${SSH_ORIGINAL_COMMAND##* }
  if [ "$command" = "$zfs_fs" ]; then
    command="send"
  else
    zfs_fs=${zfs_fs% *}
  fi
else
  echo "$0 work with \$SSH_ORIGINAL_COMMAND"
  exit 1
fi
[ -z "$to" -o -z "$zfs_fs" ] && exit 1
zfs_fs=$(zfs list -Honame $zfs_fs)

trace=/var/tmp/zfs_sent_$(echo $zfs_fs | sed 's/\//_/g')
from=$(hostname -s)

case "$command" in
  received)
    now=$(cat $trace)
    if [ -z "$now" ]; then
      echo "$trace does not exists" >&2
      exit 1
    fi
    logger -p local4.info "zfs set lastbackup:$to=$from-$to-$now $zfs_fs"
    zfs set lastbackup:$to=$from-$to-$now $zfs_fs
    echo ${from}-${to}-${now}
    rm $trace
    exit 0
  ;;
  send)
    zfs_fs=$(zfs list -Honame $zfs_fs)
    [ -n "$zfs_fs" ] || exit 1
    now=$(date +%s)
    logger -p local4.info "zfs snapshot $zfs_fs@$from-$to-$now"
    zfs snapshot $zfs_fs@$from-$to-$now
    lastsnap=$(zfs get lastbackup:$to $zfs_fs 2>/dev/null)
    if lastsnap=$(zfs get lastbackup:$to $zfs_fs 2>/dev/null); then
      # si on a un last, on l'utilise
      logger -p local4.info "zfs send -i @$lastsnap $zfs_fs@$from-$to-$now"
      zfs send -RI @$lastsnap $zfs_fs@$from-$to-$now
    else
      # sinon on envoie tout
      logger -p local4.info "zfs send $zfs_fs@$from-$to-$now"
      zfs send -R $zfs_fs@$from-$to-$now
    fi
    echo $now > $trace
    exit 0
  ;;
  connect)
    echo "$(hostname -s) ok"
    exit 0
  ;;
  *)
    echo "$0 $*: invalid syntax"
    exit 1
  ;;
esac

