#!/bin/sh
#
# Installe une synchro
#
if [ $# -lt 2 ]; then
  echo "usage: $0 SRC@SRCHOST DEST [SSHKEY] [KEEPEXPR]"
  echo
  echo "example:"
  echo "  $0 srchost:zdata/shares/volume zdata/shares/volumedest"
  echo
  exit 1
fi

SRC=$1
DST=$2
SSHKEY=${3:-~/.ssh/id_ed25519_sync}
KEEPEXPR=${4:-""}

SRCHOST=${SRC%%:*}
SRCVOL=${SRC#*:}
DSTHOST=$(hostname -s)

if ! [ -e "$SSHKEY" ]; then
  echo "Create $SSHKEY"
  ssh-keygen -t ed25519 -f $SSHKEY -N '' -C 'sync script on '$(hostname -s)
fi

PUBKEY=$(awk '{printf("%s %s",$1,$2);}' $SSHKEY.pub)
echo $PUBKEY | grep -q '^ssh-' || exit 1
if ssh root@$SRCHOST "echo ok" | grep -q ok; then
  if ! env SSH_AUTH_SOCK='' ssh -oIdentitiesOnly=yes -oBatchMode=yes -axi $SSHKEY $SRCHOST $DSTHOST $SRCVOL connect 2>/dev/null; then
    if ssh root@$SRCHOST "grep '$PUBKEY' .ssh/authorized_keys"; then
      echo "Remove key from $SRCHOST"
      ssh root@$SRCHOST "sed -i.bak '/$PUBKEY/d' .ssh/authorized_keys"
    fi
    echo "command=\"$(realpath $(dirname $0))/send_zfs.sh\" $(cat $SSHKEY.pub)" | ssh root@$SRCHOST 'cat >> .ssh/authorized_keys'
  else
    echo "La cle est deja installée"
  fi
else
  echo "you need a working key to connect to root@$SRCHOST"
  exit 1
fi

if [ "$(env SSH_AUTH_SOCK='' ssh -oIdentitiesOnly=yes -oBatchMode=yes -axi $SSHKEY $SRCHOST $DSTHOST $SRCVOL connect)" != "ok" ]; then
  exit 1
fi

SRCVOL=$(env SSH_AUTH_SOCK='' ssh -oIdentitiesOnly=yes -oBatchMode=yes -axi $SSHKEY $SRCHOST $DSTHOST $SRCVOL list | head -1)

D=$(zfs list -Honame $DST 2>/dev/null)
if ! [ -z "$D" ]; then
  echo "la destination $D existe deja"
  DST=$D
fi

if crontab -l | grep 'sync_zfs_from.*'$SRCHOST:$SRCVOL; then
  echo "Deja dans la crontab"
  exit 0
fi

echo "Lancer une premiere synchro:"
echo "$(realpath $(dirname $0))/sync_zfs_from.sh $SSHKEY $SRCHOST:$SRCVOL $DST $KEEPEXPR"
echo 
echo "Puis mettre cette commande dans la crontab"

