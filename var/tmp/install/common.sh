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

configure_profile() {
  local REPLY profile profiles=()
  if profile=$(getarg pf.profile); then
    echo $profile > $installbase/profile.txt
    echo "Profile selected: $profile"
    return 0
  fi
  for profile in $(jq -r '.profile | keys[]' "$installbase/config.json"); do
    profiles+=($profile)
  done
  case ${#profiles[@]} in
    0)
      error "no profiles"
      return 1
      ;;
    1)
      echo ${profiles[@]} > $installbase/profile.txt
      return 0
      ;;
    *)
      local width=0
      for profile in ${profiles[@]}; do
        width=$(( width > ${#profile} ? width : ${#profile} ))
      done
      while true; do
        echo "Available profiles:"
        for profile in ${profiles[@]}; do
          printf "  %-$((width))s - %s\n" $profile "$(get_config .profile.$profile.slogan)"
        done
        read -rp "Choose profile (default=${profiles[0]}): "
        if [[ -z $REPLY ]]; then
          echo ${profiles[0]} > $installbase/profile.txt
          return 0
        fi
        for profile in ${profiles[@]}; do
          if [[ $profile = "$REPLY" ]]; then
            echo $profile > $installbase/profile.txt
            return 0
          fi
        done
        echo "No such profile: $REPLY"
      done
      ;;
  esac
}

get_profile() {
  [[ -f $installbase/profile.txt ]] || return $(error "profile not configured")
  cat $installbase/profile.txt
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

get_config() {
  local result
  result=$(jq -M -r "$1" "$installbase/config.json")
  if [[ $result != "null" ]]; then
    echo "$result"
  fi
}

get_profile_config() {
  get_config ".profile.$(get_profile)$1"
}

has_modifier() {
  jq -M -r '.modifiers[]' "$installbase/config.json" | grep -q "^$1$"
}

get_label() {
  get_profile_config ".partition.$1.label"
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
