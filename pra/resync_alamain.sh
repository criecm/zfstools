#!/bin/sh
#
exiterror() {
  echo $@
  exit 1
}

usage() {
  exiterror "usage: $0 sourcehost:zfs [dstzfs]"
}

srczfs=${1#*:}
sourcehost=${1%:*}
dstzfs=${2:-$srczfs}

if [ $# -lt 1 ] || [ $# -gt 2 ] || [ -z "$srczfs" ] || [ -z "$sourcehost" ] || [ "$srczfs" = "$sourcehost" ]; then
  usage
fi

there() {
  echo "ssh -x $sourcehost $@" >&2
  ssh -x "$sourcehost" "$@"
}
here() {
  echo "$@" >&2
  eval "$@"
}

[ "$(zfs get -Hp readonly "${dstzfs}" | cut -w -f3)" = "on" ] || exiterror "${dstzfs} not readonly here (not destination ?)"

TMPDIR="/tmp/resync_${sourcehost}_$(echo ${srczfs} | sed 's@/@__@g')"
mkdir -p ${TMPDIR}
LISTSRC="${TMPDIR}/src"
LISTDST="${TMPDIR}/dst"
snaphead="${sourcehost%.*}-$(hostname -s)"

echo "disable cron"
crontab -l | sed 's@^\([0-9].*sync_zfs_pra_from.sh .* '$dstzfs'\)$@#\1@' | crontab -

LOGNAME=sync_$(echo $DST | sed 's/[^-a-zA-Z0-9_]/_/g;')
if ! lockf -t 0 /var/run/$LOGNAME.lock /bin/echo "no lock"; then
  echo "sync is running"
  pgrep -fl sync_zfs_pra_from.sh
  exit 1
fi

there "zfs list -H -oname -t snapshot -s creation -Honame,guid -r '$srczfs'" > "$LISTSRC" || exiterror "unable to list source snapshots"
zfs list -H -oname -t snapshot -s creation -Honame,guid -r "$dstzfs" > $LISTDST || exiterror "unable to list dest snapshots"

errcount=0
errwith=""
lastsrcsnap=$(there zfs list -Honame -t snapshot -s creation "$srczfs" | grep @${snaphead} | tail -1 | sed 's/^.*@//')
if [ -z "${lastsrcsnap}" ]; then
  echo "pas de snapshot de synchro a la source ${srczfs}@${snaphead}*"
  exit 1
fi
lastvalidsnap=$(there zfs get -Hovalue lastpra:$(hostname -s) "$srczfs")
# evite un grep d'une chaine vide plus bas
[ -z "${lastvalidsnap}" ] && lastvalidsnap="nEXISTEpasNULLEpart"
# boucle pour chaque zfs enfant
for fs in $(sed 's/@.*$//' "$LISTSRC" | grep "${srczfs}/" | sort -u | sed "s#^${srczfs}/##;"); do
  lastdsthere=$(grep "^${dstzfs}/${fs}@${snaphead}" "$LISTDST" | cut -f1 | tail -1 | cut -d@ -f2)
  if [ -n "${lastdsthere}" ]; then
    last_on_dest=$(grep "^${srczfs}/${fs}@${lastdsthere}[[:space:]]" "$LISTSRC" | cut -f1 | cut -d@ -f2)
  else
    last_on_dest=""
  fi
  if [ -z "${last_on_dest}" ]; then
  # source doesn't have the last received sync snapshot
    # search for last common one by guid
    for guid in $(grep "^${dstzfs}/${fs}@" "$LISTDST" | cut -f2); do
      grep -q "^${srczfs}/${fs}@.*[[:space:]]${guid}$" "$LISTSRC" && last_on_dest=$(grep "^$fs@.*[[:space:]]${guid}$" "$LISTSRC" | cut -f1 | cut -d@ -f2)
    done
    # destroy $fs on dest if no common snapshot on dest
    if [ -z "${last_on_dest}" ]; then
      echo " * no sync snap for ${dstzfs}/${fs}: destroy $fs"
      here zfs destroy -r "${dstzfs}/${fs}"
    fi
  fi
  if [ -n "${last_on_dest}" ] && [ "$(grep "^${dstzfs}/${fs}@" "${LISTDST}" | tail -1 | cut -f1)" != "${last_on_dest}" ]; then
    # rollback to last common
    echo " * rollback to ${dstzfs}/${fs}@${last_on_dest} on dest"
    here zfs rollback -r "${dstzfs}/${fs}@${last_on_dest}"
  fi
  last_on_src=$(fgrep "${srczfs}/${fs}@${lastsrcsnap}" "${LISTSRC}" | tail -1 | cut -f1 | cut -d@ -f2)
  [ -z "${last_on_src}" ] && continue
  if [ -n "${last_on_dest}" ] && [ "${last_on_dest}" != "${last_on_src}" ]; then
    # suppression des snapshots de synchro intermediaires inutiles avant synchro
    echo " * delete needless sync snapshots on ${sourcehost}:${srczfs}/${fs}"
    there "zfs list -Honame -tsnapshot ${srczfs}/${fs} | grep '${srczfs}/${fs}@$snaphead' | grep -Ev '@($last_on_dest|$last_on_src|$lastvalidsnap)' | xargs -tL1 zfs destroy -d"
    # synchro vers $lastsrcsnap, incrémental si possible
    echo " * sync ${srczfs}/${fs}@${last_on_src} ${last_on_dest:+"(inc from @${last_on_dest})"} to ${dstzfs}/${fs}"
    if ! there zfs send -R ${last_on_dest:+"-I@${last_on_dest}"} "${srczfs}/${fs}@${last_on_src}" | here "mbuffer -q | zfs receive -vF ${dstzfs}/${fs}"; then
      errcount=$(( errcount + 1 ))
      errwith="${fs}\n$errwith"
    fi
  fi
done

if [ $errcount -eq 0 ]; then
  lastdst=$(zfs list -Honame -t snapshot -s creation -r -d1 "${dstzfs}" | grep @${snaphead} | tail -1 | cut -d@ -f2)
  there "zfs list -r -d1 -t snapshot -Honame,guid ${srczfs}" > "$LISTSRC"
  if ! grep -q "^${srczfs}@${lastdst}[[:space:]]" "$LISTSRC"; then
    # le dernier snapshot de synchro recu n'etc pas sur la source
    # on en cherche un par guid
    for guid in $(zfs list -Hoguid -t snapshot -s creation "${dstzfs}"); do
      grep -q "[[:space:]]${guid}$" "$LISTSRC" && lastdst=$(grep "[[:space:]]${guid}$" "$LISTSRC" | cut -f1 | cut -d@ -f2)
    done
    # rollback au dernier commun
    if [ -n "${lastdst}" ]; then
      echo " * rollback to ${dstzfs}@${lastdst}"
      here zfs rollback -r "${dstzfs}@${lastdst}"
    fi
  fi
  lastsrc=$(grep "^${srczfs}@${lastsrcsnap}[[:space:]]" "$LISTSRC" | cut -f1 | cut -d@ -f2)
  if [ -z "${lastsrc}" ]; then
    # inutile ? ne devrait pas pouvoir arriver
    echo " **** PAS inutile... ****"
    for guid in $(zfs list -Hoguid -tsnap -S creation ${dstzfs}); do
      grep -q "^${srczfs}@.*[[:space:]]${guid}$" "$LISTSRC" && lastsrc=$(grep "[[:space:]]${guid}$" | cut -f1 | cut -d@ -f2) && break
    done
  fi
  if [ -z "${lastsrc}" ]; then
    echo "Erreur avec $srczfs: $lastsrcsnap a disparu !" >&2
    exit 1
  fi
  # suppression des snapshots de synchro intermediaires inutiles
  there "zfs list -Honame -tsnapshot -r -d1 ${srczfs} | grep '^${srczfs}@${snaphead}' | grep -Ev '${srczfs}@(${lastsrc}|${lastdst}|${lastvalidsnap})' | xargs -t -L1 zfs destroy -d"
  if zfs list ${dstzfs}@${lastsrc} > /dev/null 2>&1; then
    zfs rollback -r ${dstzfs}@${lastsrc}
  elif [ "${lastsrc}" != "${lastdst}" ]; then
    there zfs send -I"@${lastdst}" "${srczfs}${lastsrc}" | here "mbuffer -q | zfs receive -vF ${dstzfs}" || exiterror "PB a la synchro finale"
  fi 
  lastsrcsnap=${lastsrc}
  lastsnaptime=${lastsrcsnap##*-}
  there "zfs set lastpra:$(hostname -s)=${lastsrc} ${srczfs} && echo ${lastsnaptime} > zfs_sent_$(echo $srczfs | sed 's@/@_@g')-$(hostname -s)"

  echo "re-enable cron"
  crontab -l | sed 's@^#\([0-9].*sync_zfs_pra_from.sh .* '$dstzfs'\)$@\1@' | crontab -

else
  echo "$errcount ERREURS"
  echo "$errwith"
fi
rm -rf "$TMPDIR"

