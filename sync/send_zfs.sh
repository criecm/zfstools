#!/bin/sh -e
#
# script d'envoi de zfs avec bookmarks
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

bookmark='#to_'$to
trace=/var/tmp/zfs_sent_$(echo $zfs_fs | sed 's/\//_/g')
from=$(hostname -s)

case "$command" in
  list)
    zfs list -Honame -r $zfs_fs
    exit 0
  ;;
  received)
    now=$(cat $trace)
    if [ -z "$now" ]; then
      echo "$trace does not exists" >&2
      exit 1
    fi
    zfs list -H -oname -t bookmark "$zfs_fs$bookmark" > /dev/null 2>&1 && zfs destroy "$zfs_fs$bookmark"
    zfs bookmark $zfs_fs@$from-$to-$now "$zfs_fs$bookmark"
    zfs destroy $zfs_fs@$from-$to-$now
    echo ${from}-${to}-${now}
    rm $trace
    exit 0
  ;;
  send)
    zfs_fs=$(zfs list -Honame $zfs_fs)
    [ -n "$zfs_fs" ] || exit 1
    now=$(date +%s)
    zfs snapshot $zfs_fs@$from-$to-$now
    if zfs list -H -oname -t bookmark "$zfs_fs$bookmark" > /dev/null 2>&1; then
      # si on a un bookmark, on l'utilise
      zfs send -i $bookmark $zfs_fs@$from-$to-$now
      echo $now > $trace
    else
      # sinon on envoie le snapshot entier
      zfs send $zfs_fs@$from-$to-$now
    fi
    exit 0
  ;;
  connect)
    echo "ok"
    exit 0
  ;;
  *)
    echo "$0 $*: invalid syntax"
    exit 1
  ;;
esac

