[[ -v installbase ]] || source /var/tmp/install/common.sh

mount_misc() {
  remount /dev || return
  remount /dev/pts || return
  remount /proc || return
  remount /sys || return
  remount /run || return
  remount /sys/firmware/efi/efivars || return
}

umount_misc() {
  uremount /dev/pts || return
  uremount /dev || return
  uremount /proc || return
  uremount /sys/firmware/efi/efivars || return
  uremount /sys || return
  uremount /run || return
}

postmount_script() {
  local storage=$(get_profile .storage)
  [[ $storage ]] || return
  local script=$installbase/storage/$storage/postmount
  if [[ ! -f $script ]]; then
    echo "File not found: $script"
    return 0
  fi
  $script
}

mount_rootfs() {
  local label device storage vgname
  storage=$(get_profile .storage)
  [[ $storage ]] || return
  label=$(get_config ".storage.$storage.partition.root")
  vgname=$(get_config ".storage.$storage.vgname")
  if [[ $vgname ]]; then
    label=$vgname-$label
  fi
  device=$(blkid --label $label) || return
  mount -m $device $sysroot
}

mount_home() {
  local label device storage vgname
  storage=$(get_profile .storage)
  [[ $storage ]] || return
  label=$(get_config ".storage.$storage.partition.home")
  vgname=$(get_config ".storage.$storage.vgname")
  if [[ $vgname ]]; then
    label=$vgname-$label
  fi
  device=$(blkid --label $label) || return
  mount -m $device $sysroot/home
}

mount_opt() {
  local label device storage vgname
  storage=$(get_profile .storage)
  [[ $storage ]] || return
  label=$(get_config ".storage.$storage.partition.opt")
  [[ $label ]] || return 0
  vgname=$(get_config ".storage.$storage.vgname")
  if [[ $vgname ]]; then
    label=$vgname-$label
  fi
  device=$(blkid --label $label) || return
  mount -m $device $sysroot/opt
}

mount_efisys() {
  local label device storage
  storage=$(get_profile .storage)
  [[ $storage ]] || return
  label=$(get_config ".storage.$storage.partition.efi")
  device=$(blkid --label $label) || return
  mount --mkdir=0700 -o fmask=0077 -o dmask=0077 -o shortname=winnt $device $sysroot/boot/efi
}

configure_machine_id() {
  mkdir -p $sysroot/etc
  head -c 16 /dev/urandom | od -A n -t x1 | sed 's/ //g' > $sysroot/etc/machine-id
}

copy_logs() {
  [[ -f $installbase/pflaster.log ]] || return
  mkdir -p $sysroot/var/log/pflaster
  cp $installbase/pflaster.log $sysroot/var/log/pflaster
}

cleanup_boot_entries() {
  local bootnum bootnums
  bootnums=$(efibootmgr | sed -n -E 's/^Boot([A-F0-9]+)\b.*\bLinux Boot Manager\b.*$/\1/p')
  for bootnum in $bootnums; do
    efibootmgr --bootnum $bootnum --delete-bootnum || return
  done
}

install_groups() {
  local pack packs=()
  while read -r pack; do
    packs+=("$pack")
  done < <(get_packages_groups)
  dnf_group_install_rootfs "${packs[@]}"
}

remove_packages() {
  local pack packs=()
  while read -r pack; do
    packs+=("$pack")
  done < <(get_packages_excludes)
  dnf_remove_rootfs "${packs[@]}"
}

install_packages() {
  local pack packs=()
  while read -r pack; do
    packs+=("$pack")
  done < <(get_packages_regular)
  dnf_install_rootfs "${packs[@]}"
}

copy_common() {
  local storage
  storage=$(get_profile .storage)
  mkdir -p $sysroot$installbase/storage/$storage
  cp $installbase/storage/$storage/* $sysroot$installbase/storage/$storage
  cp $installbase/common.sh $sysroot$installbase || return
  cp $installbase/config.json $sysroot$installbase || return
}

copy_profile() {
  mkdir -p $sysroot$installbase
  [[ -f $installbase/profile.json ]] || return
  cp $installbase/profile.json $sysroot$installbase
}

install_kernel() {
  dnf_install_rootfs kernel-$(uname -r)
}

pre_script() {
  local storage script
  storage=$(getarg pf.storage)
  [[ $storage ]] || {
    echo "skipping pre: storage not preconfigured"
    return 0
  }
  script=$installbase/storage/$storage/pre
  [[ -f $script ]] || return 0
  $script
}

storage_script() {
  local storage script
  storage=$(get_profile .storage)
  [[ $storage ]] || return
  script=$installbase/storage/$storage/storage
  [[ -f $script ]] || return
  $script
}

run_hook_chrooted() {
  local storage software
  storage=$(get_profile .storage)
  software=$(get_profile .software)
  [[ $storage ]] || return
  [[ $software ]] || return
  run_chrooted $installbase/$1 || return
  run_chrooted $installbase/storage/$storage/$1 || return
  run_chrooted $installbase/software/$software/$1 || return
}

postgroups_chrooted() {
  run_hook_chrooted postgroups
}

preinstall_chrooted() {
  run_hook_chrooted preinstall
}

postinstall_chrooted() {
  run_hook_chrooted postinstall
}

configure_rootpw() {
  local pw pwhash REPLY
  pwhash=$(get_config .rootpw)
  if [[ $pwhash ]]; then
    jqi ".rootpw = \"$pwhash\""
    return
  fi
  if [[ $(get_profile .rootpw) ]]; then
    read -rp "A root password is configured. Keep it? [Y/n] "
    [[ -z $REPLY || $REPLY =~ [yY] ]] && return
  fi
  read -rp "Set a root password? [y/N] "
  if [[ -z $REPLY || $REPLY =~ [nN] ]]; then
    jqi "del(.rootpw)"
    return
  fi
  while :; do
    ask_new_key "rootpw" pw && break
  done
  pwhash=$(openssl passwd -6 -stdin <<< "$pw")
  jqi ".rootpw = \"$pwhash\""
}

configure_hostname() {
  local hostname REPLY
  hostname=$(get_config .hostname)
  if [[ $hostname ]]; then
    jqi ".hostname = \"$hostname\""
    return
  fi
  hostname=$(get_profile .hostname)
  if [[ $hostname ]]; then
    read -rp "Hostname $hostname is configured. Keep it? [Y/n] "
    [[ -z $REPLY || $REPLY =~ [yY] ]] && return
  fi
  while :; do
    read -rp "Choose hostname: "
    [[ $REPLY ]] && break
  done
  jqi ".hostname = \"$REPLY\""
}

configure_user() {
  local users username pw pwhash REPLY
  users=$(get_config '.user // {} | keys[]')
  if [[ $users ]]; then
    jqi ".user = $(get_config .user)"
    return
  fi
  users=$(get_profile '.user // {} | keys[]')
  if [[ $users ]]; then
    read -rp "User $users is configured. Keep it? [Y/n] "
    [[ -z $REPLY || $REPLY =~ [yY] ]] && return
  fi
  if [[ $(get_profile .rootpw) ]]; then
    read -rp "Create a user? [y/N] "
    if [[ -z $REPLY || $REPLY =~ [nN] ]]; then
      jqi "del(.user)"
      return
    fi
  fi
  while :; do
    read -rp "Choose a username: " username
    [[ $username ]] && break
  done
  while :; do
    ask_new_key "password for $username" pw && break
  done
  pwhash=$(openssl passwd -6 -stdin <<< "$pw")
  jqi ".user.$username.admin = true"
  jqi ".user.$username.password = \"$pwhash\""
}

configure_keyboard() {
  local default keyboard result REPLY
  default=$(get_config .keyboard)
  default=${default:-us}
  keyboard=$(get_profile .keyboard)
  while :; do
    read -rp "Choose keyboard (default=${keyboard:-$default}): "
    [[ -z $REPLY ]] && break
    loadkeys -q -p "$REPLY" 2> /dev/null && break
  done
  result=${REPLY:-${keyboard:-$default}}
  jqi ".keyboard = \"$result\""
  loadkeys "$result"
}

is_valid_locale() {
  local arg
  arg=${1%.*}
  localectl list-locales | sed -n -E 's/^([^.]+)\..*/\1/p' | grep -q "^$arg$"
}

configure_locale() {
  local default lang result reply
  default=$(get_config .lang)
  default=${default:-en_us}
  lang=$(get_profile .lang)
  while :; do
    read -rp "choose locale (default=${lang:-$default}): "
    [[ -z $reply ]] && break
    is_valid_locale "$reply" && break
  done
  result=${reply:-${lang:-$default}}
  jqi ".lang = \"$result\""
}

tz_tree() {
  local tz len=${#1}
  if (( len == 0 )); then
    return 1
  else
    tz=$(timedatectl list-timezones | grep -i "^$1")
    if [[ $tz = *$'\n'* ]]; then
      echo "${tz,,}" | sed -E "s/^.{$len}(.).*/\\1/" | sort -u | tr -d '\n'
      return 1
    elif [[ $tz ]]; then
      echo "${tz,,}"
      return 0
    else
      return 1
    fi
  fi
}

tz_user_read() {
  local result mychar buf buftest
  rm -f /tmp/tztree.txt
  tz_tree
  while :; do
    read -s -N 1 mychar
    mychar=${mychar,,}
    if [[ $mychar = $'\177' ]]; then
      if [[ $buf ]]; then
        buf=${buf:0:$(( ${#buf} - 1 ))}
      fi
      if result=$(tz_tree "$buf"); then
        printf "\r\033[K$buf -> $result"
      elif [[ $buf ]]; then
        printf "\r\033[K$buf [$result]"
      else
        printf "\r\033[K"
      fi
    elif [[ $mychar = $'\12' ]]; then
      if tz_tree "$buf" > /dev/null; then
        result=$(timedatectl list-timezones | grep -i "^$buf")
        echo $result > /tmp/tztree.txt
        printf "\r\033[K$result\n"
        break
      fi
    elif [[ $mychar =~ [a-z0-9/_+-] ]]; then
      buf=$buf${mychar}
      if result=$(tz_tree "$buf"); then
        printf "\r\033[K$buf -> $result"
      else
        printf "\r\033[K$buf [$result]"
      fi
    fi
  done
}

configure_timezone() {
  local timezone
  timezone=$(get_config .timezone)
  if [[ $timezone ]]; then
    jqi ".timezone = \"$timezone\""
    return
  fi
  timezone=$(get_profile .timezone)
  if [[ $timezone ]]; then
    read -rp "Timezone $timezone is configured. Keep it? [Y/n] "
    [[ -z $REPLY || $REPLY =~ [yY] ]] && return
  fi
  echo "Starting timezone selection. Confirm with Return when an arrow appears."
  echo "Try \"utc\", \"country/city\" or \"continent/capital\"."
  tz_user_read || return
  [[ -f /tmp/tztree.txt ]] || return
  jqi ".timezone = \"$(< /tmp/tztree.txt)\""
}

configure() {
  while :; do
    configure_keyboard
    configure_locale
    configure_timezone
    configure_disk
    choose storage
    choose software
    configure_rootpw
    configure_hostname
    configure_user
    jq -M -f $installbase/mask.jq $installbase/profile.json
    read -rp "Is this correct? [Y/n] "
    if [[ -z $REPLY || $REPLY =~ [yY] ]]; then
      return 0
    fi
  done
}

install_sdboot() {
  findmnt -n $sysroot/boot/efi &> /dev/null || return
  bootctl install --root=$sysroot --esp-path=/boot/efi
}

extract_late_tgz() {
  tar --no-same-owner -xf /tmp/late.tgz --directory /
  cp -r $sysroot/etc/yum.repos.d /etc/yum.repos.d
}

boot_loader_entry() {
  if efibootmgr | grep -q -E '^Boot\S+\s+\bFedora\b.*'; then
    return 0
  fi
  local storage label uuid partuuid partnum
  local storage=$(get_profile .storage)
  [[ $storage ]] || return
  label=$(get_config .storage.$storage.partition.efi)
  [[ $label ]] || return
  uuid=$(lsblk -n --filter "LABEL == \"$label\"" -o UUID)
  [[ $uuid ]] || return
  partuuid=$(lsblk -n --filter "UUID == \"$uuid\"" -o PARTUUID)
  [[ $partuuid ]] || return
  disk=$(get_disk)
  [[ $disk ]] || return
  partnum=$(parted -j $disk print | jq -r ".disk.partitions[]|select(.uuid==\"$partuuid\")|.number")
  [[ $partnum ]] || return
  echo efibootmgr --create --disk=$disk --part=$partnum --label="Fedora" --loader='EFI\BOOT\BOOTX64.EFI'
}

do_everything() {

  # Preparations
  echo "Type 'C-b c stop' to halt after installation, or 'C-b c stop --now' to halt earlier."
  run pre_script || return
  run configure || return
  run storage_script || return
  run mount_rootfs || return
  run mount_home || return
  run mount_opt || return
  run mount_efisys || return
  run cleanup_boot_entries || return
  run extract_late_tgz || return
  run postmount_script || return

  # Actual installation begins here
  run mount_misc || return
  run copy_profile || return
  run copy_common || return
  run install_groups || return
  run postgroups_chrooted || return
  run remove_packages || return
  run install_packages || return
  run configure_machine_id || return
  run install_sdboot || return
  run preinstall_chrooted || return
  run install_kernel || return
  run postinstall_chrooted || return
  run umount_misc || return
  run boot_loader_entry || return
  run copy_logs || return
  if [[ -f /tmp/stop ]]; then
    echo "Halted. 'stop -c' to continue"
    sleep inf
  fi
  reboot
}

return 2> /dev/null || {
  do_everything
}
