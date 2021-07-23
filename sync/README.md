# paire de scripts pour synchro de volumes zfs

* La synchro est initialisée depuis la destination, avec une cle ssh dédiée
* La source doit accepter cette cle ssh avec `command=".../send_zfs.sh"` dans /root/.ssh/authorized_keys

## howto

exemple pour synchroniser SRVSOURCE:zdata/shares/truc vers SRVDEST:zdata/shares/truc:

- Créer une cle ssh: SRVDEST# ``ssh-keygen -t ed25519 -f ~/id_ed25519_sync``
- Copier la cle publique sur SRVSOURCE avec *command=*: SRVDEST# ``echo 'command="/usr/local/admin/sysutils/zfs/sync/send_zfs.sh" '$(cat ~/id_ed25519_sync.pub) | ssh SRVSOURCE 'cat >> .ssh/authorized_keys'``
- Vérifier la cle & le script distant: SRVDEST# ``ssh -oBatchMode=yes -oIdentitiesOnly=yes -axi ~/id_ed25519_sync SRVSOURCE zdata/shares/truc list``
    ok
- Lancer la synchro: SRVDEST# ``/usr/local/admin/sysutils/zfs/sync/sync_zfs_from.sh ~/id_ed25519_sync SRVSOURCE:zdata/shares/truc zdata/shares/truc 36h15d6w6m1y``
- Mettre ça dans SRVDEST# ``crontab -e`` pour automatiser
- les logs sont dans SRVDEST:/var/log/sync_zdata_shares_truc.log

## snapshots a la destination
- ajouter une expression au format ``36h15d6w6m1y`` à la commande pour créer et maintenir des snapshots à la destination avec le script $SNAPSCRIPT (ou ../zfs_snap_make par défaut)
