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
  jq "$@" $profile > $tmpfile || return
  mv $tmpfile $profile
}

choose() {
  local what="$1" REPLY choice options=()
  [[ $what ]] || return
  choice=$(getarg pf.$what)
  if [[ $choice ]]; then
    jqi ".$what = \"$choice\""
    echo "$what=$choice preselected"
    return
  elif [[ -f $installbase/profile.json ]] && jq -e "has(\"$what\")" $installbase/profile.json > /dev/null; then
    choice=$(jq -r ".$what" $installbase/profile.json)
    read -rp "$what=$choice <- keep this choice? [Y/n] "
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
  [[ $1 ]] || return
  [[ -f $installbase/profile.json ]] || return
  jq -r "$1" $installbase/profile.json
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
  disks=$(get_disks)
  disks=${disks% }
  while true; do
    if [[ -z ${disks// /} ]]; then
      echo "FATAL: no disks"
      return 1
    elif [[ ${disks// /} = "$disks" ]]; then
      jqi ".disk = \"$(get_path $disks)\""
      return 0
    else
      [[ $lsblk_printed ]] || { lsblk ; lsblk_printed=1 ; }
      read -r -p "Please choose disk for installation [${disks// /|}]: "
      path=$(get_path $REPLY) || continue
      jqi ".disk = \"$path\""
      return 0
    fi
  done
}

get_disk() {
  get_config .disk
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

get_users() {
  jq -r '.user | keys[]' "$installbase/config.json"
}

create_user() {
  local user_exists user=$1 useradd_opts=()
  if [[ -e /home/$user ]]; then
    user_exists=1
  fi
  if [[ $user_exists ]]; then
    useradd_opts+=("-m")
  fi
  if [[ $(get_config .user.$user.system) = "true" ]]; then
    useradd_opts+=("--system")
  fi
  useradd -U "${useradd_opts[@]}" -p "$(get_config .user.$user.password)" "$user"
  if [[ $(get_config .user.$user.admin) = "true" ]]; then
    usermod -a -G wheel "$user"
  fi
  if [[ $user_exists ]]; then
    chown -R $user: /home/$user
    return 0
  fi
  local sshkey
  sshkey="$(get_config .user.$user.sshkey)"
  if [[ ${sshkey:-null} != "null" ]]; then
    mkdir -p /home/$user/.ssh
    chmod 700 /home/$user/.ssh
    echo "$sshkey" > /home/$user/.ssh/authorized_keys
    chmod 600 /home/$user/.ssh/authorized_keys
  fi
  mkdir -p /home/$user/.bashrc.d
  echo "alias ll='ls -lAZ --color=auto'" > /home/$user/.bashrc.d/aliases.sh
  chown -R $user: /home/$user
}

create_users() {
  local user users=$(get_users)
  for user in $users; do
    create_user $user
  done
}

set_root_pw() {
  local rootpw
  rootpw=$(get_config .rootpw)
  if [[ ${rootpw:-null} = "null" ]]; then
    return 0
  fi
  chmod 600 /etc/shadow
  sed -i -E "s@^root:\!unprovisioned:(.*)@root:$rootpw:\1@" /etc/shadow
  chmod 000 /etc/shadow
}

trigger_autorelabel() {
  rpm --quiet -q selinux-policy || return 0
  touch /.autorelabel
}

set_enforcing() {
  rpm --quiet -q selinux-policy || return 0
  sed -i -E 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
}

set_permissive() {
  rpm --quiet -q selinux-policy || return 0
  sed -i -E 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
}

set_nopasswd() {
  chmod 640 /etc/sudoers
  sed -i -E 's/^%wheel\b.*/%wheel ALL=(ALL) NOPASSWD: ALL/' /etc/sudoers
  chmod 440 /etc/sudoers
}

configure_sdboot() {
  findmnt -n /boot/efi &> /dev/null || return
  mkdir -p /boot/efi/loader
  echo "timeout 5" >> /boot/efi/loader/loader.conf
}

set_timezone() {
  # currently hardcoded, make this a config
  timedatectl set-timezone Europe/Berlin
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

set_target_firstboot() {
  [[ -f /usr/share/systemux/tmux.conf ]] || return
  local software=$(get_profile .software)
  [[ $software ]] || return
  systemctl set-default firstboot.target
  set_permissive
  # sesearch -s init_t -t screen_exec_t -c file -A
  # sesearch -s init_t -t init_t -c file -A
  chcon -t bin_t /usr/bin/tmux
}

manage_repo() {
  (( $1 == 0 || $1 == 1 )) || return
  [[ $2 ]] || return
  local file=/etc/yum.repos.d/$(basename $2)
  [[ -f $file ]] || return 0
  sed -i -E \
    -e "s/^enabled=.*/enabled=$1/" \
    -e "s/^enabled_metadata=.*/enabled_metadata=$1/" \
    $file
}

disable_repo() {
  manage_repo 0 $1
}

enable_repo() {
  manage_repo 1 $1
}

loadkeys_config() {
  # https://unix.stackexchange.com/questions/85374/loadkeys-gives-permission-denied-for-normal-user
  chmod u+s $(which loadkeys)
}

configure_hostname() {
  local hostname
  hostname="$(get_config .hostname)"
  if [[ $hostname ]]; then
    hostnamectl hostname $hostname
  elif [[ -f /etc/hostname ]]; then
    hostnamectl hostname $(< /etc/hostname)
  else
    echo "ERROR: hostname not configured"
    return 1
  fi
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
