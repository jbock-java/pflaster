installbase=/tmp/install

error() {
  1>&2 echo "ERROR: $@"
  echo 1
}

has_tpm() {
  [[ -a /sys/class/tpm ]] && ls /sys/class/tpm/tpm* &> /dev/null
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

get_config() {
  local result
  result=$(jq -M -r "$1" "$installbase/config.json")
  if [[ $result != "null" ]]; then
    echo $result
  fi
}

configure_disk() {
  [[ -f $installbase/disk ]] && return 0
  local path disks REPLY lsblk_printed=false
  disks=$(get_disks)
  disks=${disks% }
  while true; do
    if [[ -z ${disks// /} ]]; then
      echo "FATAL: no disks"
      return 1
    elif [[ ${disks// /} = "$disks" ]]; then
      get_path $disks > $installbase/disk
      return 0
    else
      $lsblk_printed || { lsblk ; lsblk_printed=true ; }
      read -r -p "Please choose disk for installation [${disks// /|}]: "
      path=$(get_path $REPLY) || continue
      echo $path > $installbase/disk
      return 0
    fi
  done
}

get_disk() {
  [[ -f $installbase/disk ]] || return 1
  cat $installbase/disk
}

get_packages_groups() {
  local packages result=()
  packages=$(get_config '.packages[]') || return
  for pack in $packages; do
    if [[ $pack = @* && $pack != @^* ]]; then
      result+=(${pack:1})
    fi
  done
  if (( ${#pack[@]} > 0 )); then
    echo ${result[@]}
  fi
}

get_packages_environments() {
  local packages result=()
  packages=$(get_config '.packages[]') || return
  for pack in $packages; do
    if [[ $pack = @^* ]]; then
      result+=(${pack:2})
    fi
  done
  if (( ${#pack[@]} > 0 )); then
    echo ${result[@]}
  fi
}

get_packages_excludes() {
  local packages result=()
  packages=$(get_config '.packages[]') || return
  for pack in $packages; do
    if [[ $pack = -* ]]; then
      result+=(${pack:1})
    fi
  done
  if (( ${#pack[@]} > 0 )); then
    echo ${result[@]}
  fi
}

get_packages_regular() {
  local packages result=()
  packages=$(get_config '.packages[]') || return
  for pack in $packages; do
    if [[ $pack != @* && $pack != -* ]]; then
      result+=($pack)
    fi
  done
  if (( ${#pack[@]} > 0 )); then
    echo ${result[@]}
  fi
}
