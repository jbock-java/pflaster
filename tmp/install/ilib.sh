[[ -v installbase ]] || source /tmp/install/common.sh

source $installbase/partlib.sh

dnf_configure_repos() {
  local script=$installbase/profile/$(get_profile)/dnf_config
  [[ -f $script ]] || return 0
  $script || return
  if [[ $(get_config .copy_repos) = "true" ]]; then
    mkdir -p $sysroot/etc/yum.repos.d
    cp /etc/yum.repos.d/*.repo $sysroot/etc/yum.repos.d
  fi
}

mount_misc() {
  remount /proc || return
  remount /sys || return
  remount /run || return
  remount /sys/firmware/efi/efivars || return
  remount /dev || return
}

dnf_setup() {
  [[ -e /etc/yum.repos.d ]] && return 0
  ln -s /etc/anaconda.repos.d /etc/yum.repos.d
  dnf_configure_repos
}

os_release() {
  sed -n -E 's/^VERSION_ID=(\S+)/\1/p' /etc/os-release
}

dnf_install_rootfs() {
  echo "dnf install: $@"
  dnf4 -qy --color=never install --nogpgcheck --releasever=$(os_release) --installroot $sysroot "$@"
}

dnf_remove_rootfs() {
  echo "dnf remove: $@"
  dnf4 -qy --color=never remove --nogpgcheck --releasever=$(os_release) --installroot $sysroot "$@"
}

dnf_environment_install_rootfs() {
  echo "dnf environment install: $@"
  dnf4 -qy --color=never environment install --nogpgcheck --releasever=$(os_release) --installroot $sysroot "$@"
}

dnf_group_install_rootfs() {
  echo "dnf group install: $@"
  dnf4 -qy --color=never group install --nogpgcheck --releasever=$(os_release) --installroot $sysroot "$@"
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

configure_hostname() {
  mkdir -p $sysroot/etc
  local hostname
  hostname="$(get_config .hostname)"
  echo "${hostname:-box}" > $sysroot/etc/hostname
}

configure_machine_id() {
  mkdir -p $sysroot/etc
  head -c 16 /dev/urandom | od -A n -t x1 | sed 's/ //g' > $sysroot/etc/machine-id
}

configure_dracut() {
  local modules
  modules=$(get_profile_config '.dracut_modules[]' | tr '\n' ' ')
  modules=${modules% }
  if [[ $modules ]]; then
    mkdir -p $sysroot/etc/dracut.conf.d
    echo "add_dracutmodules+=\" $modules \"" > $sysroot/etc/dracut.conf.d/pflaster.conf
  fi
}

extract_late_tgz() {
  tar --no-same-owner -xf /tmp/late.tgz --directory /
}

copy_logs() {
  [[ -f $installbase/pflaster.log ]] || return 1
  mkdir -p $sysroot/var/log/pflaster
  cp $installbase/pflaster.log $sysroot/var/log/pflaster
}

copy_dnf_config() {
  mkdir -p $sysroot/etc/yum.repos.d
  cp /etc/yum.repos.d/*.repo $sysroot/etc/yum.repos.d
}

cleanup_boot_entries() {
  local bootnum bootnums
  bootnums=$(efibootmgr | sed -n -E 's/^Boot([A-F0-9]+)\b.*\bLinux Boot Manager\b.*$/\1/p')
  for bootnum in $bootnums; do
    efibootmgr --bootnum $bootnum --delete-bootnum || return
  done
}

install_packages() {
  local pack_env pack_group pack_exclude pack_regular
  pack_env=$(get_packages_environments)
  pack_group=$(get_packages_groups)
  pack_exclude=$(get_packages_excludes)
  pack_regular=$(get_packages_regular)
  if [[ $pack_env ]]; then
    dnf_environment_install_rootfs $pack_env || return
  fi
  if [[ $pack_group ]]; then
    dnf_group_install_rootfs $pack_group || return
  fi
  if [[ $pack_exclude ]]; then
    dnf_remove_rootfs $pack_exclude || return
  fi
  if [[ $pack_regular ]]; then
    dnf_install_rootfs $pack_regular || return
  fi
  return 0
}

copy_common() {
  mkdir -p $sysroot/$installbase
  cp $installbase/common.sh $sysroot/$installbase || return 1
  cp $installbase/config.json $sysroot/$installbase
}

copy_profile() {
  mkdir -p $sysroot/$installbase
  local profile=$(get_profile)
  cp $installbase/profile/$profile/preinstall $sysroot/$installbase || return 1
  cp $installbase/profile/$profile/postinstall $sysroot/$installbase
}

install_kernel() {
  dnf_install_rootfs kernel-modules-core-$(uname -r)
}

chrooted_postinstall() {
  mkdir -p $sysroot/root
  cp $installbase/chrooted/postinstall $sysroot/root/postinstall
  chroot $sysroot /root/postinstall
}

do_everything() {

  # Preparations
  echo "Type 'C-b c stop' to halt at the end, or 'C-b c stop --now' to halt earlier."
  run configure_disk || return
  run $installbase/profile/$(get_profile)/storage || return
  run mount_rootfs || return
  run mount_home || return
  run mount_efisys || return
  run mount_misc || return
  run dnf_setup || return

  # Actual installation begins here
  run install_packages || return
  run copy_common || return
  run copy_profile || return
  run configure_hostname || return
  run configure_machine_id || return
  run configure_dracut || return
  run extract_late_tgz || return
  run cleanup_boot_entries || return
  run_chrooted $installbase/install_sdboot || return
  run_chrooted $installbase/preinstall || return
  run install_kernel || return
  run_chrooted $installbase/postinstall || return
  run copy_dnf_config || return
  run copy_logs || return
  [[ -f /tmp/stop ]] && { echo "Halted. 'stop -c' to continue" ; sleep inf ; }
  reboot
}
