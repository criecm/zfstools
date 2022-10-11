# paire de scripts pour synchro PRA de volume zfs

* La synchro est initialisée depuis la destination, avec une cle ssh dédiée
* La source doit accepter cette cle ssh avec `command=".../send_zfs_pra.sh"` dans /root/.ssh/authorized_keys

## howto

en une ligne: ``./new_pra.sh``

exemple pour synchroniser SRVSOURCE:zdata/shares/truc vers SRVDEST:zdata/shares/truc:

- Créer une cle ssh: SRVDEST# ``ssh-keygen -t ed25519 -f ~/id_ed25519_pra``
- Copier la cle publique sur SRVSOURCE avec *command=*: SRVDEST# ``echo 'command="/usr/local/admin/sysutils/zfs/pra/send_zfs_pra.sh" '$(cat ~/id_ed25519_sync.pub) | ssh SRVSOURCE 'cat >> .ssh/authorized_keys'``
- Vérifier la cle & le script distant: SRVDEST# ``ssh -oBatchMode=yes -oIdentitiesOnly=yes -axi ~/id_ed25519_pra SRVSOURCE zdata/shares/truc list``
    ok
- Lancer la synchro: SRVDEST# ``/usr/local/admin/sysutils/zfs/pra/sync_zfs_pra_from.sh ~/id_ed25519_pra SRVSOURCE:zdata/shares/truc zdata/shares/truc 36h15d6w6m1y``
- Mettre ça dans SRVDEST# ``crontab -e`` pour automatiser
- les logs sont dans SRVDEST:/var/log/sync_zdata_shares_truc.log

## en cas de probleme

avec une cle ssh autorisée chez root à la source et dans un tmux:
``resync_alamain.sh zdata/shares/truc SRVSOURCE``

