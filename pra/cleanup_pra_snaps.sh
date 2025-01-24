#!/bin/sh
#
# clean old PRA snapshots
#
warn() {
  echo $@ >&2
}

debug() {
  if [ -n "$DEBUG" ]; then
    echo -n "DEBUG: " >&2
    echo $@ >&2
  fi
}

if [ $# -gt 0 ]; then
  zfses=$@
else
  zfses=$(zfs get -slocal -Honame,property all | grep lastpra: | cut -f1 | sort -u)
fi

for z in $zfses; do
  zfs=$(zfs list -Honame ${z}) || continue
  debug "on ZFS ${zfs}"
  if pgrep -qf "zfs send .* ${zfs}"; then
    warn "zfs send en cours"
    exit 1
  fi
  for lastpra in $(zfs get -Hoproperty -s local all ${zfs} | grep "^lastpra:"); do
    prahost=${lastpra#lastpra:}
    prasnap=$(zfs get -Hovalue -s local ${lastpra} ${zfs})
    prahead=${prasnap%-*}
    pradate=${prasnap##*-}
    if ! zfs list -Honame ${zfs}@${prasnap} >/dev/null 2>&1; then
      warn "${zfs} lastpra:${prahost} snapshot desn't exist. delete property $lastpra"
      echo "zfs inherit $lastpra ${zfs}"
      continue
    fi
    if [ "$pradate" -lt "$(( $(date +%s) - ( 86400 * 7 ) ))" ]; then
      date=$(env LC_TIME=fr_FR.UTF-8 zfs get -Hovalue creation ${zfs}@${prasnap})
      warn "${zfs}: lastpra on $prahost is $(( ( $(date +%s) - pradate ) / 86400 )) days old ($date)"
    fi
    debug "pra found: $prasnap at $pradate on $prahost"
    kept=0
    deleted=0
    keeplist="$prasnap "
    for snap in $(zfs list -Honame -t snapshot ${zfs} | grep -F "@${prahead}"); do
      snapdate=${snap##*-}
      if [ "$snapdate" -lt "$pradate" ]; then
        debug "DELETE $snap"
        deleted=$((deleted+1))
        echo "zfs destroy -r $snap"
        # temp
        keeplist=$keeplist"${snap#*@} "
      else
        kept=$((kept+1))
        keeplist=$keeplist"${snap#*@} "
        debug "KEEP $snap"
      fi
    done
    [ "$deleted" -gt 0 ] || [ "$kept" -gt 2 ] && warn "$kept snapshots kept on ${zfs} ($deleted deleted)"
    #echo $keeplist
    zfs list -rtsnapshot -Honame ${zfs} | grep -F "@${prahead}" | grep -Ev "($(echo $keeplist | tr ' ' '|'))" | while read snap; do
      [ "${snap##*-}" -lt ${pradate} ] && echo "zfs destroy $snap" || debug "KEEPALSO $snap"
    done
  done
done
