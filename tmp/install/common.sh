installbase=/tmp/install
sysroot=/mnt/sysroot

getarg() {
  local token arg="$1" len=${#1}
  shift
  set -- $(< /proc/cmdline)
  for token in "$@"; do
    if [[ $token = "$arg" ]]; then
      echo "1"
      return 0
    elif [[ ${token:0:$(( len + 1))} = "$arg=" ]]; then
      echo "${token:$(( len + 1 ))}"
      return 0
    fi
  done
  return 1
}

error() {
  1>&2 echo "ERROR: $@"
  echo 1
}

run() {
  echo "Running: $1"
  $1 || return $(error "$1")
  if [[ -f /tmp/pause ]]; then
    echo "Halted. 'stop -c' to continue."
    sleep inf
    rm -f /tmp/pause
  fi
  echo "OK: $1"
}

run_chrooted() {
  echo "Running: chroot $sysroot $1"
  chroot $sysroot $1 || return $(error "chroot $sysroot $1")
  if [[ -f /tmp/pause ]]; then
    echo "Halted. 'stop -c' to continue."
    sleep inf
    rm -f /tmp/pause
  fi
  echo "OK: chroot $sysroot $1"
}

get_profile() {
  local profile
  if profile=$(getarg pf.profile); then
    echo $profile
  else
    echo "lvm_luks"
  fi
}

remount() {
  if findmnt -n $sysroot/$1 &> /dev/null; then
    return 0
  fi
  mount --bind -m $1 $sysroot/$1
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

get_profile_config() {
  get_config ".profile.$(get_profile)$1"
}

has_modifier() {
  jq -M -r '.modifiers[]' "$installbase/config.json" | grep -q "^$1$"
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
