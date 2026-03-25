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

run() {
  echo "Running: $@"
  "$@" || {
    echo "ERROR: $@"
    return 1
  }
  if [[ -f /tmp/pause ]]; then
    echo "Halted. Type 'stop -c' to continue."
    sleep inf
  fi
  echo "OK: $@"
}

run_chrooted() {
  [[ -f $sysroot$installbase/profile.json ]] || return
  if [[ -f $sysroot$1 ]]; then
    echo "Running: chroot $sysroot $@"
  else
    echo "Not found: $sysroot$1"
    return 0
  fi
  chroot $sysroot "$@" || return
  if [[ -f /tmp/pause ]]; then
    echo "Halted. Type 'stop -c' to continue."
    sleep inf
  fi
  echo "OK: chroot $sysroot $@"
}

run_spawned() {
  [[ -f $sysroot$installbase/profile.json ]] || return
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

jqi() {
  local tmpfile profile=$installbase/profile.json
  [[ -f $profile ]] || { echo "{}" > $profile ; }
  tmpfile=$(mktemp) || return
  jq -cM "$@" $profile > $tmpfile || return
  mv $tmpfile $profile
}

choose() {
  local what="$1" REPLY choice options=()
  [[ $what ]] || return
  choice=$(getarg pf.$what)
  if [[ $choice ]]; then
    jqi ".$what = \"$choice\""
    echo "$what=$choice specified via command line"
    return
  elif [[ -f $installbase/profile.json ]] && jq -e "has(\"$what\")" $installbase/profile.json > /dev/null; then
    choice=$(jq -r ".$what" $installbase/profile.json)
    read -rp "$what $choice is configured. Keep it? [Y/n] "
    [[ -z $REPLY || $REPLY =~ [yY] ]] && return
  fi
  for choice in $(jq -r ".$what | keys[]" $installbase/config.json); do
    options+=($choice)
  done
  case ${#options[@]} in
    0)
      echo "ERROR: Got nothing to choose from."
      return 1
      ;;
    1)
      jqi ".$what = \"${options[@]}\""
      echo "$what=${options[@]} is the only option"
      return
      ;;
    *)
      local col=0
      for choice in "${options[@]}"; do
        (( col < ${#choice} && ( col = ${#choice} ) ))
      done
      while true; do
        echo "$what:"
        for choice in "${options[@]}"; do
          printf "  %-$((col))s - %s\n" $choice "$(jq -r .$what.$choice.banner $installbase/config.json)"
        done
        read -rp "Choose $what (or prefix): "
        [[ $REPLY ]] || continue
        local matches=0 remember
        for choice in "${options[@]}"; do
          if [[ $choice = ${REPLY}* ]]; then
            (( matches++ ))
            remember=$choice
          fi
        done
        if (( matches == 0 )); then
          echo "No such $what: $REPLY"
        elif (( matches == 1 )); then
          jqi ".$what = \"$remember\""
          echo "$what=$remember selected"
          return 0
        else
          echo "Insufficient prefix: $REPLY"
        fi
      done
      ;;
  esac
}

get_profile() {
  local result
  [[ $1 ]] || return
  [[ -f $installbase/profile.json ]] || return
  result=$(jq -M -r "$1" $installbase/profile.json 2> /dev/null) || return 0
  if [[ ${result:-null} != "null" ]]; then
    echo "$result"
  fi
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
  result=$(jq -M -r "$1" "$installbase/config.json" 2> /dev/null) || return 0
  if [[ ${result:-null} != "null" ]]; then
    echo "$result"
  fi
}

configure_disk() {
  local path disks REPLY lsblk_printed
  disks=$(get_profile .disk)
  if [[ $disks ]]; then
    read -rp "Installation target $disks is configured. Keep it? [Y/n] "
    if [[ -z $REPLY || $REPLY =~ [Yy] ]]; then
      return
    fi
  fi
  disks=$(get_disks)
  disks=${disks% }
  while :; do
    if [[ -z ${disks// /} ]]; then
      echo "FATAL: no disks"
      return 1
    elif [[ ${disks// /} = "$disks" ]]; then
      jqi ".disk = \"$(get_path $disks)\""
      return 0
    else
      [[ $lsblk_printed ]] || { lsblk ; lsblk_printed=1 ; }
      read -r -p "Please choose disk for installation [${disks// /|}]: "
      path=$(get_path $REPLY)
      [[ $path ]] || continue
      jqi ".disk = \"$path\""
      return 0
    fi
  done
}

get_disk() {
  get_profile .disk
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

get_config_packages() {
  local storage
  get_config '.packages[]'
  storage=$(get_profile .storage)
  [[ $storage ]] || return
  get_config ".storage.$storage.packages[]"
}

get_packages_groups() {
  local pack
  while read -r pack; do
    if [[ $pack = @* && $pack != @^* ]]; then
      echo "${pack:1}"
    fi
  done < <(get_config_packages)
}

get_packages_excludes() {
  local pack
  while read -r pack; do
    if [[ $pack = -* ]]; then
      echo "${pack:1}"
    fi
  done < <(get_config_packages)
}

get_packages_regular() {
  local pack
  while read -r pack; do
    if [[ $pack != @* && $pack != -* ]]; then
      echo "$pack"
    fi
  done < <(get_config_packages)
}

get_disksize() {
  local disk bytes
  disk=$(get_disk) || return
  bytes=$(lsblk -b -n --filter "PATH == '$disk'" -o SIZE)
  echo $(( bytes / ( 1024 * 1024 ) ))
}

get_ram_mb() {
  local kb
  kb=$(sed -n -E 's/^MemTotal:\s+\b([[:digit:]]+)\b.*\bkB$/\1/p' /proc/meminfo)
  [[ $kb ]] || return
  echo $(( kb / 1024 ))
}

get_only_child() {
  [[ $1 ]] || return
  local kname children
  kname=$(lsblk -n --filter "PATH == '$1'" -o KNAME)
  children=$(lsblk -n --filter "PKNAME == '$kname'" -o PATH | tr '\n' ' ')
  children=${children% }
  [[ $children = "${children// /}" ]] || {
    echo "ERROR: more than one child"
    return 1
  }
  echo $children
}

trigger_autorelabel() {
  rpm --quiet -q selinux-policy || return 0
  touch /.autorelabel
}

set_enforcing() {
  rpm --quiet -q selinux-policy || return 0
  sed -i -E 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
}

set_nopasswd() {
  chmod 640 /etc/sudoers
  sed -i -E 's/^%wheel\b.*/%wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
  chmod 440 /etc/sudoers
}

is_swap_on_drive() {
  local path
  for path in $(lsblk -n --filter "FSTYPE == \"swap\"" -o PATH); do
    if ! zramctl -n | grep -q ^$path; then
      return 0
    fi
  done
  return 1
}

configure_zswap() {
  if ! is_swap_on_drive; then
    return 0
  fi
  mkdir -p /etc/systemd
  touch /etc/systemd/zram-generator.conf
  for conf in /boot/efi/loader/entries/*x86_64.conf; do
    [[ -f $conf ]] || continue
    sed -i -E "/^options\b/ s/\$/ zswap.enabled=1 zswap.shrinker_enabled=1 zswap.compressor=lz4 zswap.max_pool_percent=25/" $conf
  done
}

configure_sdboot() {
  local conf
  findmnt -n /boot/efi &> /dev/null || return
  mkdir -p /boot/efi/loader
  echo "timeout 5" >> /boot/efi/loader/loader.conf
}

set_timezone() {
  local timezone
  timezone=$(get_profile .timezone)
  timedatectl set-timezone ${timezone:-UTC}
}

set_rtc_utc() {
  timedatectl set-local-rtc 0
}

set_target_anyboot() {
  local target software
  software=$(get_profile .software)
  if [[ $software ]]; then
    target=$(get_config ".software.$software.target")
  fi
  systemctl set-default ${target:-multi-user}.target
}

disable_repo() {
  local file=/etc/yum.repos.d/$(basename $1)
  [[ -f $file ]] || return 0
  sed -i -E "s/^enabled=.*$/enabled=0/" $file
}

enable_repo() {
  local file=/etc/yum.repos.d/$(basename $1)
  [[ -f $file ]] || return 0
  sed -i -E "0,/^enabled=/{s/^enabled=.*$/enabled=1/}" $file
}

loadkeys_config() {
  # https://unix.stackexchange.com/questions/85374/loadkeys-gives-permission-denied-for-normal-user
  chmod u+s $(which loadkeys)
}

jm() {
  local acc="$1"
  shift
  if (( $# == 1 )); then
    jq -cM ". += [{${1%=*}:\"${1#*=}\"}]" <<< "$acc"
  elif (( $# == 2 )); then
    jq -cM ". += [{${1%=*}:\"${1#*=}\",${2%=*}:\"${2#*=}\"}]" <<< "$acc"
  elif (( $# == 3 )); then
    jq -cM ". += [{${1%=*}:\"${1#*=}\",${2%=*}:\"${2#*=}\",${3%=*}:\"${3#*=}\"}]" <<< "$acc"
  elif (( $# == 4 )); then
    jq -cM ". += [{${1%=*}:\"${1#*=}\",${2%=*}:\"${2#*=}\",${3%=*}:\"${3#*=}\",${4%=*}:\"${4#*=}\"}]" <<< "$acc"
  elif (( $# == 5 )); then
    jq -cM ". += [{${1%=*}:\"${1#*=}\",${2%=*}:\"${2#*=}\",${3%=*}:\"${3#*=}\",${4%=*}:\"${4#*=}\",${5%=*}:\"${5#*=}\"}]" <<< "$acc"
  else
    return 1
  fi
}

storage_task_preserve() {
  local label dev t
  label=$(jq -r ".label | select(. != null)" <<< "$1")
  [[ $label ]] || return 0
  dev=$(jq -r ".dev | select(. != null)" <<< "$1")
  t=$(jq -r ".t | select(. != null)" <<< "$1")
  if [[ $t = "ext4" && $(e2label $dev) != "$label" ]]; then
    e2label $dev $label || return
  fi
}

storage_task_wipe() {
  local label dev t
  label=$(jq -r ".label | select(. != null)" <<< "$1")
  [[ $label ]] || return
  dev=$(jq -r ".dev | select(. != null)" <<< "$1")
  t=$(jq -r ".t | select(. != null)" <<< "$1")
  case $t in
    efi)
      mkfs.vfat -n $label -F 32 $dev || return
      ;;
    ext4)
      mkfs.ext4 -q -L $label $dev <<< y || return
      ;;
    *)
      echo "unknown type: $1"
      return 1
      ;;
  esac
}

storage_task_create() {
  local name t size vgname
  name=$(jq -r ".name | select(. != null)" <<< "$1")
  t=$(jq -r ".t | select(. != null)" <<< "$1")
  size=$(jq -r ".size | select(. != null)" <<< "$1")
  vgname=$(jq -r ".vgname | select(. != null)" <<< "$1")
  [[ $name ]] || return
  [[ $size ]] || return
  [[ $vgname ]] || return
  (( size == 0 )) && return
  lvcreate -qy --size ${size}M --name $name $vgname || return
  case $t in
    swap)
      mkswap /dev/mapper/$vgname-$name
      swaplabel -L $vgname-$name /dev/mapper/$vgname-$name
      ;;
    ext4)
      mkfs.ext4 -q -L $vgname-$name /dev/mapper/$vgname-$name <<< y || return
      ;;
    *)
      echo "unknown type: $1"
      return 1
      ;;
  esac
}

storage_task_drop() {
  local vgname name
  vgname=$(jq -r ".vgname | select(. != null)" <<< "$1")
  name=$(jq -r ".name | select(. != null)" <<< "$1")
  if [[ -e /dev/mapper/$vgname-$name ]]; then
    lvremove -f $vgname/$name || return
  fi
}

run_storage_task() {
  echo "Running task: $1"
  local task
  task=$(jq -r .task <<< "$1")
  case $task in
    preserve)
      storage_task_preserve "$1"
      return
      ;;
    wipe)
      storage_task_wipe "$1"
      return
      ;;
    create)
      storage_task_create "$1"
      return
      ;;
    drop)
      storage_task_drop "$1"
      return
      ;;
    *)
      echo "unknown task: $1"
      return 1
      ;;
  esac
}

run_storage_tasks() {
  local tasks="$1"
  local m n tasks
  while :; do
    echo "Partitioning tasks:"
    (( n = 1 ))
    while read -r m; do
      echo "$n. $m"
      (( n++ ))
    done <<< "$tasks"
    read -rp "Proceed with these tasks? [y/N] "
    if [[ $REPLY =~ [yY] ]]; then
      break
    fi
  done
  while read -r m; do
    run_storage_task "$m" || return
  done <<< "$tasks"
}

ask_new_key() {
  local reply0 reply1
  read -rsp "Choose $1: " reply0
  echo
  (( ${#reply0} >= 8 )) || {
    echo "ERROR: minimum 8 characters"
    return 1
  }
  [[ $reply0 = "${reply0// /}" ]] || {
    echo "ERROR: spaces not allowed"
    return 1
  }
  read -rsp "Confirm $1: " reply1
  echo
  if [[ $reply0 = "$reply1" ]]; then
    eval "$2=$reply0"
    return 0
  else
    echo "ERROR: no match"
    return 1
  fi
}

configure_keyboard() {
  local keyboard
  keyboard=$(get_profile .keyboard)
  keyboard=${keyboard:-us}
  if [[ -f /etc/vconsole.conf ]]; then
    if grep -q ^KEYMAP= /etc/vconsole.conf; then
      sed -i -E "s/^KEYMAP=.*/KEYMAP=\"$keyboard\"/" /etc/vconsole.conf
    else
      echo "KEYMAP=\"$keyboard\"" > /etc/vconsole.conf
    fi
  else
    echo "KEYMAP=\"$keyboard\"" > /etc/vconsole.conf
  fi
  keyboard=${keyboard%.*}
  keyboard=${keyboard%_*}
  if localectl list-x11-keymap-layouts | grep -q "^$keyboard$"; then
    localectl set-x11-keymap "$keyboard"
  fi
}
