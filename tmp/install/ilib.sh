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

mount_misc() {
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

mount_rootfs() {
  local device
  device=$(blkid --label luks-root)
  mount -m $device $sysroot
}

mount_home() {
  local device
  device=$(blkid --label luks-home)
  mount -m $device $sysroot/home
}

mount_efisys() {
  [[ -e $sysroot/boot/efi ]] && return 0
  local device
  device=$(blkid --label EFISYS)
  mount --mkdir=0700 -o fmask=0077 -o dmask=0077 -o shortname=winnt $device $sysroot/boot/efi
}

configure_hostname() {
  mkdir -p $sysroot/etc
  # todo: make hostname configurable
  echo "box" > $sysroot/etc/hostname
}

configure_machine_id() {
  mkdir -p $sysroot/etc
  head -c 16 /dev/urandom | od -A n -t x1 | sed 's/ //g' > $sysroot/etc/machine-id
}

print_cmdline_options() {
  echo "root=UUID=$(get_uuid luks-root)"
  echo "rd.luks.uuid=$(get_uuid pvroot)"
  echo "rd.lvm.vg=luks"
  echo "rd.shell"
}

configure_cmdline() {
  mkdir -p $sysroot/etc/kernel
  print_cmdline_options | tr '\n' ' ' > $sysroot/etc/kernel/cmdline
  echo >> $sysroot/etc/kernel/cmdline
}

configure_luks() {
  mkdir -p $sysroot/etc/dracut.conf.d
  echo "luks UUID=$(get_uuid pvroot) none discard,tpm2-device=auto" > $sysroot/etc/crypttab
  echo 'add_dracutmodules+=" tpm2-tss lvm "' > $sysroot/etc/dracut.conf.d/tpm2.conf
}

print_fstab() {
  echo "UUID=$(get_uuid EFISYS)    /boot/efi vfat umask=0077,shortname=winnt 0 2"
  echo "UUID=$(get_uuid luks-root) /         ext4 defaults 1 2"
  echo "UUID=$(get_uuid luks-home) /home     ext4 defaults 1 2"
}

configure_fstab() {
  mkdir -p $sysroot/etc
  print_fstab >> $sysroot/etc/fstab
}

configure_kernel_install() {
  mkdir -p $sysroot/etc/kernel
  cp $installbase/install.conf $sysroot/etc/kernel/install.conf
}

configure_rootdir() {
  cat $installbase/aliases.sh >> $sysroot/root/.bashrc
  cp /root/.vimrc $sysroot/root
  cp /root/.bash_profile $sysroot/root
  cp /tmp/install/config.json $sysroot/root
}

copy_logs() {
  [[ -f /tmp/install/pflaster.log ]] || return 1
  mkdir -p $sysroot/var/log/pflaster
  cp /tmp/install/pflaster.log $sysroot/var/log/pflaster
}

chrooted_install_sdboot() {
  local bootnum bootnums
  bootnums=$(efibootmgr | sed -n -E 's/^Boot([0-9]+).*\bLinux Boot Manager\b.*$/\1/p')
  for bootnum in $bootnums; do
    efibootmgr --bootnum $bootnum --delete-bootnum || return $?
  done
  mkdir -p $sysroot/root
  cp $installbase/chrooted/install_sdboot $sysroot/root
  chroot $sysroot /root/install_sdboot
}

install_packages() {
  local deps=(
    vim-enhanced
    vim-default-editor
    systemd-boot-unsigned
    efibootmgr
    selinux-policy
    lvm2
  )
  dnf_group_install_rootfs core || return $?
  dnf_remove_rootfs nano-default-editor || return $?
  dnf_install_rootfs "${deps[@]}"
}

install_kernel() {
  dnf_install_rootfs kernel-modules-core-$(uname -r)
}

chrooted_postinstall() {
  mkdir -p $sysroot/root
  cp $installbase/chrooted/postinstall $sysroot/root/postinstall
  chroot $sysroot /root/postinstall
}

# WARNING! This clears the partition table.
do_everything() {

  # Preparations
  configure_disk || return $(error "configure disk")
  create_partitions || return $(error "create partitions")
  mount_rootfs || return $(error "mount rootfs")
  mount_home || return $(error "mount home")
  mount_efisys || return $(error "mount efisys")
  mount_misc || return $(error "mount misc")
  dnf_setup || return $(error "dnf setup")

  # Actual installation begins here
  install_packages || return $(error "install packages")
  configure_hostname || return $(error "configure hostname")
  configure_machine_id || return $(error "configure machine id")
  configure_cmdline || return $(error "configure cmdline")
  configure_luks || return $(error "configure luks")
  configure_fstab || return $(error "configure fstab")
  configure_kernel_install || return $(error "configure kernel install")
  configure_rootdir || return $(error "configure rootdir")
  chrooted_install_sdboot || return $(error "chrooted install sdboot")
  install_kernel || return $(error "install kernel")
  chrooted_postinstall || return $(error "chrooted postinstall")
  [[ -f /tmp/stop ]] && { echo "zZz..."; sleep inf ; }
  copy_logs || return $(error "copy logs")
  reboot
}
