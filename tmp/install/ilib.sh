[[ -v installbase ]] || source /tmp/install/common.sh

source $installbase/partlib.sh

sysroot=/mnt/sysroot

dnf_configure_repos() {
  mkdir -p $sysroot/etc/yum.repos.d
  for repo in /etc/yum.repos.d/*.repo; do
    if [[ $repo =~ .*/fedora\.repo ]]; then
      sed -i -E \
        -e 's/^(\[.*\])$/\1\nsslverify=0/' \
        -e "s|^countme=.*|countme=0|" \
        -e "s|^enabled=.*|enabled=1|" \
        $repo
    elif [[ $repo =~ .*/fedora-updates\.repo ]]; then
      sed -i -E \
        -e 's/^(\[.*\])$/\1\nsslverify=0/' \
        -e "s|^countme=.*|countme=0|" \
        -e "s|^enabled=.*|enabled=1|" \
        $repo
    else
      sed -i -E "s|^enabled=.*|enabled=0|" $repo
    fi
    cp $repo $sysroot/$repo
  done
}

mount_other_things() {
  mount -B -m /proc $sysroot/proc || return $?
  mount -B -m /sys $sysroot/sys || return $?
  mount -B -m /sys/firmware/efi/efivars $sysroot/sys/firmware/efi/efivars || return $?
  mount -B -m /dev $sysroot/dev
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
  dnf4 -y install --nogpgcheck --releasever=$(os_release) --installroot $sysroot "$@"
}

dnf_remove_rootfs() {
  dnf4 -y remove --nogpgcheck --releasever=$(os_release) --installroot $sysroot "$@"
}

dnf_group_install_rootfs() {
  dnf4 -y group install --nogpgcheck --releasever=$(os_release) --installroot $sysroot "$@"
}

mount_rootfs() {
  [[ -e $sysroot ]] && return 0
  local device
  device=$(blkid --label linuxroot)
  mount -m $device $sysroot
}

mount_efisys() {
  [[ -e $sysroot/boot/efi ]] && return 0
  local device
  device=$(blkid --label EFISYS)
  mount --mkdir=0700 -o fmask=0077 -o dmask=0077 -o shortname=winnt $device $sysroot/boot/efi
}

rootfs_configure_hostname() {
  [[ -e $sysroot ]] || return 1
  mkdir -p $sysroot/etc
  # todo: take hostname from cmdline, or ask the user
  echo "box" > $sysroot/etc/hostname
}

rootfs_configure_machine_id() {
  [[ -e $sysroot ]] || return 1
  mkdir -p $sysroot/etc
  head -c 16 /dev/urandom | od -A n -t x1 | sed 's/ //g' > $sysroot/etc/machine-id
}

rootfs_configure_cmdline() {
  [[ -e $sysroot ]] || return 1
  mkdir -p $sysroot/etc/kernel
  echo "root=UUID=$(get_uuid linuxroot) ro" > $sysroot/etc/kernel/cmdline
}

print_fstab() {
  echo "UUID=$(get_uuid linuxroot) /         ext4 x-systemd.device-timeout=0 0 0"
  echo "UUID=$(get_uuid EFISYS   ) /boot/efi vfat umask=0077,shortname=winnt 0 2"
}

rootfs_configure_fstab() {
  [[ -e $sysroot ]] || return 1
  mkdir -p $sysroot/etc
  print_fstab >> $sysroot/etc/fstab
}

rootfs_copy_kernel_install_conf() {
  [[ -e $sysroot ]] || return 1
  mkdir -p $sysroot/etc/kernel
  cp $installbase/install.conf $sysroot/etc/kernel/install.conf
}

rootfs_copy_root_config() {
  [[ -e $sysroot ]] || return 1
  cat $installbase/aliases.sh >> $sysroot/root/.bashrc
  cp /root/.vimrc $sysroot/root/.vimrc
}

run_chrooted_post_sdboot() {
  local bootnum bootnums
  bootnums=$(efibootmgr | sed -n -E 's/^Boot([0-9]+).*\bLinux Boot Manager\b.*$/\1/p')
  for bootnum in $bootnums; do
    efibootmgr --bootnum $bootnum --delete-bootnum || return $?
  done
  mkdir -p $sysroot/root
  cp $installbase/post_sdboot $sysroot/root/post_sdboot
  chroot $sysroot /root/post_sdboot
}

rootfs_install_packages() {
  [[ -e $sysroot ]] || return 1
  local deps
  deps=(
    vim-enhanced
    vim-default-editor
    systemd-boot-unsigned
    efibootmgr
    selinux-policy
  )
  dnf_group_install_rootfs core || return $?
  dnf_remove_rootfs nano-default-editor || return $?
  dnf_install_rootfs "${deps[@]}"
}

rootfs_install_kernel() {
  [[ -e $sysroot ]] || return 1
  local kernel_version=$(uname -r)
  local deps
  deps=(
    kernel-modules-core-$kernel_version
    kernel-core-$kernel_version
  )
  dnf_install_rootfs "${deps[@]}"
}

run_chrooted_postinstall() {
  mkdir -p $sysroot/root
  cp $installbase/postinstall $sysroot/root/postinstall
  chroot $sysroot /root/postinstall
}

# WARNING! This clears the partition table.
do_everything() {
  configure_disk || return $(error "configure_disk")
  create_partitions || return $(error "create partitions")
  mount_rootfs || return $(error "mount_rootfs")
  mount_efisys || return $(error "mount_efisys")
  mount_other_things || return $(error "mount_other_things")
  dnf_setup || return $(error "dnf_setup")
  rootfs_install_packages || return $(error "rootfs_install_packages")
  rootfs_configure_hostname || return $(error "rootfs_configure_hostname")
  rootfs_configure_machine_id || return $(error "rootfs_configure_machine_id")
  rootfs_configure_cmdline || return $(error "rootfs_configure_cmdline")
  rootfs_configure_fstab || return $(error "rootfs_configure_fstab")
  rootfs_copy_kernel_install_conf || return $(error "rootfs_copy_kernel_install_conf")
  rootfs_copy_root_config || return $(error "rootfs_copy_root_config")
  run_chrooted_post_sdboot || return $(error "run_chrooted_post_sdboot")
  rootfs_install_kernel || return $(error "rootfs_install_kernel")
  run_chrooted_postinstall || return $(error "run_chrooted_postinstall")
  [[ -f /tmp/stop ]] && { echo "zZz..."; sleep inf ; }
  reboot
}

try_again() {
  local next
  next=$(efibootmgr | sed -n -E 's/^BootCurrent:\s*(\S+)$/\1/p')
  [[ $next ]] && efibootmgr -n $next
  touch /tmp/fail
  tmux select-window -t1
}
