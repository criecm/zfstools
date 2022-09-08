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
zfs_fs=$(zfs list -Honame $zfs_fs)

bookmark='#to_'$to
trace=/var/tmp/zfs_sent_$(echo $zfs_fs | sed 's/\//_/g')_$to
from=$(hostname -s)

case "$command" in
  list)
    zfs list -Honame -r $zfs_fs
    exit 0
  ;;
  props)
    zfs get -Hp -s local,received -oproperty,value all $zfs_fs
    exit 0
  ;;
  destroy_bookmark)
   if zfs list -H -oname -t bookmark "$zfs_fs$bookmark" > /dev/null 2>&1; then
      logger -p local4.info "Force destroy bookmark zfs destroy \"$zfs_fs$bookmark\""
      zfs destroy "$zfs_fs$bookmark"
    fi
   ;;  
  received)
    now=$(cat $trace)
    if [ -z "$now" ]; then
      echo "$trace does not exists" >&2
      exit 1
    fi
    if zfs list -H -oname -t bookmark "$zfs_fs$bookmark" > /dev/null 2>&1; then
      logger -p local4.info "zfs destroy \"$zfs_fs$bookmark\""
      zfs destroy "$zfs_fs$bookmark"
    fi
    logger -p local4.info "zfs bookmark $zfs_fs@$from-$to-$now \"$zfs_fs$bookmark\""
    zfs bookmark $zfs_fs@$from-$to-$now "$zfs_fs$bookmark"
    logger -p local4.info "zfs destroy $zfs_fs@$from-$to-$now"
    zfs destroy $zfs_fs@$from-$to-$now
    echo ${from}-${to}-${now}
    rm $trace
    # menage
    if [ $(date +%u) -eq 0 -a $(date +%H) -lt 2 ]; then
      for snap in $(zfs list -r -Honame -t snapshot -d 1 $zfs_fs | grep "${zfs_fs}@${from}-${to}-" | grep -v "${zfs_fs}@${from}-${to}-${now}"); do
        logger -p local4.info "zfs destroy -r $snap (menage)"
        zfs destroy -rd $snap
      done
    fi

    exit 0
  ;;
  send)
    zfs_fs=$(zfs list -Honame $zfs_fs)
    [ -n "$zfs_fs" ] || exit 1
    now=$(date +%s)
    logger -p local4.info "zfs snapshot $zfs_fs@$from-$to-$now"
    zfs snapshot $zfs_fs@$from-$to-$now
    if zfs list -H -oname -t bookmark "$zfs_fs$bookmark" > /dev/null 2>&1; then
      # si on a un bookmark, on l'utilise
      logger -p local4.info "zfs send -i $bookmark $zfs_fs@$from-$to-$now"
      zfs send -i $bookmark $zfs_fs@$from-$to-$now
    else
      # sinon on envoie le snapshot entier
      logger -p local4.info "zfs send $zfs_fs@$from-$to-$now"
      zfs send $zfs_fs@$from-$to-$now
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

