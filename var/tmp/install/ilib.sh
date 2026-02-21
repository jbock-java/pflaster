[[ -v installbase ]] || source /var/tmp/install/common.sh

source $installbase/partlib.sh

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

postmount() {
  local script=$installbase/postmount
  if [[ ! -f $script ]]; then
    echo "File not found: $script"
    return 0
  fi
  $script
}

postgroups() {
  local script=$installbase/postgroups
  if [[ ! -f $script ]]; then
    echo "File not found: $script"
    return 0
  fi
  $script
}

mount_rootfs() {
  local device
  device=$(blkid --label $(get_label root)) || return
  mount -m $device $sysroot
}

mount_home() {
  local device
  device=$(blkid --label $(get_label home)) || return
  mount -m $device $sysroot/home
}

mount_efisys() {
  local device
  device=$(blkid --label $(get_label efi)) || return
  mount --mkdir=0700 -o fmask=0077 -o dmask=0077 -o shortname=winnt $device $sysroot/boot/efi
}

configure_machine_id() {
  mkdir -p $sysroot/etc
  head -c 16 /dev/urandom | od -A n -t x1 | sed 's/ //g' > $sysroot/etc/machine-id
}

configure_dracut() {
  local modules
  modules=$(get_profile_config '.dracut_modules[]' | tr '\n' ' ')
  modules=${modules% }
  [[ $modules ]] || return 0
  mkdir -p $sysroot/etc/dracut.conf.d
  echo "add_dracutmodules+=\" $modules \"" > $sysroot/etc/dracut.conf.d/pflaster.conf
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
  dnf_remove_rootfs "${packs[@]}" || true
}

install_packages() {
  local pack packs=()
  while read -r pack; do
    packs+=("$pack")
  done < <(get_packages_regular)
  dnf_install_rootfs "${packs[@]}"
}

install_more_packages() {
  if [[ ! -f $installbase/install_more_packages ]]; then
    echo "File not found: $installbase/install_more_packages"
    return 0
  fi
  $installbase/install_more_packages
}

copy_common() {
  mkdir -p $sysroot$installbase
  cp $installbase/common.sh $sysroot$installbase || return
  cp $installbase/config.json $sysroot$installbase
}

copy_profile() {
  mkdir -p $sysroot$installbase
  local profile=$(get_profile)
  [[ -f $installbase/profile.txt ]] || return 1
  cp $installbase/profile.txt $sysroot$installbase
}

install_kernel() {
  dnf_install_rootfs kernel-modules-core-$(uname -r)
}

run_storage() {
  local profile=$(get_profile)
  local script=$installbase/profile/$profile/storage
  [[ -f $script ]] || return 1
  $script
}

do_everything() {

  # Preparations
  echo "Type 'C-b c stop' to halt after installation, or 'C-b c stop --now' to halt earlier."
  run configure_disk || return
  run configure_profile || return
  run_storage || return
  run mount_rootfs || return
  run mount_home || return
  run mount_efisys || return
  run cleanup_boot_entries || return
  run postmount || return

  # Actual installation begins here
  run install_groups || return
  run postgroups || return
  run remove_packages || return
  run install_packages || return
  run install_more_packages || return
  run copy_common || return
  run copy_profile || return
  run configure_machine_id || return
  run configure_dracut || return
  run mount_misc || return
  run_chrooted $installbase/install_sdboot || return
  run_chrooted $installbase/preinstall || return
  run install_kernel || return
  run_chrooted $installbase/postinstall || return
  run umount_misc || return
  run copy_logs || return
  [[ -f /tmp/stop ]] && { echo "Halted. 'stop -c' to continue" ; sleep inf ; }
  reboot
}
