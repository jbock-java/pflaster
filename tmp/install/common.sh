installbase=/tmp/install

error() {
  1>&2 echo "ERROR: $@"
  echo 1
}

get_disks() {
  lsblk -n --filter "TYPE=='disk' && RM==0 && MOUNTPOINT!='[SWAP]'" -o KNAME | tr '\n' ' '
}

get_path() {
  [[ $1 ]] || return 1
  lsblk -n --filter "KNAME=='$1'" -o PATH
}

by_partlabel() {
  blkid -o device -t PARTLABEL=$1
}

get_uuid() {
  lsblk -n --filter "LABEL == '$1'" -o UUID
}

configure_disk() {
  [[ -f $installbase/disk ]] && return 0
  local path disks REPLY lsblk_printed=false
  disks=$(get_disks)
  disks=${disks% }
  while true; do
    if [[ -z $disks ]]; then
      echo "FATAL: no disks"
      return 1
    elif [[ ${disks/ /} = "$disks" ]]; then
      get_path $disks > $installbase/disk
    else
      $lsblk_printed || { lsblk ; lsblk_printed=true ; }
      read -r -p "Please choose disk for installation [${disks// /|}]: "
      path=$(get_path $REPLY) || continue
      echo $path > $installbase/disk
      break
    fi
  done
  return 0
}

get_disk() {
  [[ -f $installbase/disk ]] || return 1
  cat $installbase/disk
}
