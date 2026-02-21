installbase=/var/tmp/install
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

os_release() {
  sed -n -E 's/^VERSION_ID=(\S+)/\1/p' /etc/os-release
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
  [[ -f $sysroot$installbase/profile.txt ]] || return 1
  if [[ -f $sysroot$1 ]]; then
    echo "Running: chroot $sysroot $1"
  else
    echo "Not found: $sysroot$1"
    return 0
  fi
  chroot $sysroot $1 || return $(error "chroot $sysroot $1")
  if [[ -f /tmp/pause ]]; then
    echo "Installation is halted. Type 'stop -c' to continue."
    sleep inf
    rm -f /tmp/pause
  fi
  echo "OK: chroot $sysroot $1"
}

run_spawned() {
  [[ -f $sysroot$installbase/profile.txt ]] || return 1
  if [[ -f $sysroot$1 ]]; then
    echo "Running: systemd-nspawn -M pflaster -D $sysroot $1"
  else
    echo "Not found: $sysroot$1"
    return 0
  fi
  systemd-nspawn -M pflaster -q -D $sysroot $1 || return
  if [[ -f /tmp/pause ]]; then
    echo "Installation is halted. Type 'stop -c' to continue."
    sleep inf
    rm -f /tmp/pause
  fi
  echo "OK: systemd-nspawn $sysroot $1"
}

choose() {
  local REPLY key options=()
  if [[ -f $installbase/profile.txt ]] && grep -q -E "^$1=.*" $installbase/profile.txt; then
    return 0
  fi
  if key=$(getarg pf.$1); then
    echo "$1=$key" >> $installbase/profile.txt
    echo "Selection: $1=$key"
    return 0
  fi
  for key in $(jq -r ".$1 | keys[]" $installbase/config.json); do
    options+=($key)
  done
  case ${#options[@]} in
    0)
      echo "ERROR: Got nothing to choose from."
      return 1
      ;;
    1)
      echo "$1=${options[@]}" >> $installbase/profile.txt
      return 0
      ;;
    *)
      local width=0
      for key in "${options[@]}"; do
        width=$(( width > ${#key} ? width : ${#key} ))
      done
      while true; do
        echo "${1}:"
        for key in "${options[@]}"; do
          printf "  %-$((width))s - %s\n" $key "$(jq -r .$1.$key.banner $installbase/config.json)"
        done
        read -rp "Choose $1 (default=${options[0]}): "
        [[ $REPLY ]] || continue
        local matches=0 remember
        for key in "${options[@]}"; do
          if [[ $key = ${REPLY}* ]]; then
            (( matches++ ))
            remember=$key
          fi
        done
        if (( matches == 0 )); then
          echo "No such $1: $REPLY"
        elif (( matches == 1 )); then
          echo "$1=$remember" >> $installbase/profile.txt
          echo "Selection: $1=$remember"
          return 0
        else
          echo "Multiple matches: $REPLY"
        fi
      done
      ;;
  esac
}

get_profile() {
  [[ $1 ]] || return
  [[ -f $installbase/profile.txt ]] || return
  sed -n -E "s/^$1=(.*)/\\1/p" $installbase/profile.txt
}

remount() {
  local target=$sysroot$1
  if findmnt -n $target &> /dev/null; then
    return 0
  fi
  mount --bind -m $1 $target
}

uremount() {
  local target=$sysroot$1
  if ! findmnt -n $target &> /dev/null; then
    return 0
  fi
  umount $target || true
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

is_empty_file() {
  [[ -f $1 && ! -s $1 ]]
}

get_config() {
  local result
  result=$(jq -M -r "$1" "$installbase/config.json")
  if [[ ${result:-null} != "null" ]]; then
    echo "$result"
  fi
}

has_modifier() {
  jq -M -r '.modifiers[]' "$installbase/config.json" | grep -q "^$1$"
}


get_label() {
  [[ $1 ]] || return
  local storage=$(get_profile storage)
  [[ $storage ]] || return
  get_config ".storage.$storage.partition.$1"
}

configure_disk() {
  [[ -f $installbase/disk ]] && return
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

dnf_install_rootfs() {
  echo "dnf install: $@"
  dnf4 -qy --color=never install --nogpgcheck --releasever=$(os_release) --installroot $sysroot "$@"
}

dnf_remove_rootfs() {
  echo "dnf remove: $@"
  dnf4 -qy --color=never remove --nogpgcheck --releasever=$(os_release) --installroot $sysroot "$@"
}

dnf_group_install_rootfs() {
  echo "dnf group install: $@"
  dnf4 -qy --color=never group install --nogpgcheck --releasever=$(os_release) --installroot $sysroot "$@"
}

get_packages_groups() {
  local pack
  while read -r pack; do
    if [[ $pack = @* && $pack != @^* ]]; then
      echo "${pack:1}"
    fi
  done < <(get_config '.packages[]')
}

get_packages_excludes() {
  local pack
  while read -r pack; do
    if [[ $pack = -* ]]; then
      echo "${pack:1}"
    fi
  done < <(get_config '.packages[]')
}

get_packages_regular() {
  local pack
  while read -r pack; do
    if [[ $pack != @* && $pack != -* ]]; then
      echo "$pack"
    fi
  done < <(get_config '.packages[]')
}

get_disksize() {
  local disk bytes
  disk=$(get_disk) || return $(error "get_disk")
  bytes=$(lsblk -b -n --filter "PATH == '$disk'" -o SIZE)
  echo $(( bytes / ( 1024 * 1024 ) ))
}

get_only_child() {
  [[ $1 ]] || return $(error "param: PATH")
  local kname children
  kname=$(lsblk -n --filter "PATH == '$1'" -o KNAME)
  children=$(lsblk -n --filter "PKNAME == '$kname'" -o PATH | tr '\n' ' ')
  children=${children% }
  [[ $children = "${children// /}" ]] || return $(error "more than one child")
  echo $children
}
