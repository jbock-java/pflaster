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
  local what="$1" REPLY choice options=()
  [[ $what ]] || return
  if [[ -f $installbase/profile.txt ]] && grep -q -E "^$what=.*" $installbase/profile.txt; then
    return 0
  fi
  if choice=$(getarg pf.$what); then
    echo "$what=$choice" >> $installbase/profile.txt
    echo "$what=$choice preselected"
    return 0
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
      echo "$what=${options[@]}" >> $installbase/profile.txt
      return 0
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
          echo "$what=$remember" >> $installbase/profile.txt
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

get_users() {
  jq -r '.user | keys[]' "$installbase/config.json"
}

create_user() {
  local user_exists user=$1
  if [[ -e /home/$user ]]; then
    user_exists=1
  fi
  if [[ $user_exists ]]; then
    useradd -m -U -p "$(get_config .user.$user.password)" "$user"
  else
    useradd -U -p "$(get_config .user.$user.password)" "$user"
  fi
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
  for user in "$users"; do
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

configure_sdboot() {
  findmnt -n /boot/efi &> /dev/null || return
  mkdir -p /boot/efi/loader
  echo "timeout 30" >> /boot/efi/loader/loader.conf
}

set_timezone() {
  # currently hardcoded, make this a config
  timedatectl set-timezone Europe/Berlin
}

set_rtc_utc() {
  timedatectl set-local-rtc 0
}

set_target_multi_user() {
  systemctl set-default multi-user.target
}

set_target_graphical() {
  systemctl set-default graphical.target
}

set_target_systemux() {
  [[ -f /usr/share/systemux/tmux.conf ]] || return
  local software=$(get_profile software)
  [[ $software ]] || return
  sed -i -E "s@\\bFIRSTBOOT_SCRIPT\\b@/var/tmp/install/software/$software/firstboot@" /usr/share/systemux/tmux.conf
  if rpm --quiet -q selinux-policy; then
    sed -i -E 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
  fi
  systemctl set-default systemux.target
}
