installbase=/tmp/install
sysroot=/mnt/sysroot

by_partlabel() {
  blkid -o device -t PARTLABEL=$1
}

get_path() {
  lsblk -n --filter "KNAME=='$1'" -o PATH
}

get_uuid() {
  lsblk -n --filter "LABEL == '$1'" -o UUID
}

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

get_disks() {
  lsblk -n --filter "TYPE=='disk' && RM==0 && MOUNTPOINT!='[SWAP]'" -o KNAME | tr '\n' ' '
}

get_disk() {
  [[ -f $installbase/disk ]] && return 0
  local disks REPLY
  disks=$(get_disks)
  disks=${disks% }
  if [[ ${disks/ /} = "$disks" ]]; then
    echo $disks > $installbase/disk
  else
    lsblk
    read -r -p "Please choose disk for installation [${disks// /|}]: "
    echo $REPLY > $installbase/disk
  fi
}

print_parted_commands() {
  local rootsize=16384
  local homesize=4096
  local efisize=2048
  local pos=1
  echo "mklabel gpt"
  echo "mkpart EFISYS fat32 ${pos}MiB $(( pos + efisize ))MiB"
  (( pos += efisize ))
  echo "set 1 esp on"
  echo "mkpart linuxroot ext4 ${pos}MiB $(( pos + rootsize ))MiB"
  (( pos += rootsize ))
  echo "mkpart linuxhome ext4 ${pos}MiB $(( pos + homesize ))MiB"
  (( pos += homesize ))
}

# WARNING! This clears the partitions table.
create_partitions() {
  local disk part disk_path
  get_disk
  disk=$(< $installbase/disk)
  disk_path=$(get_path $disk)
  [[ $disk_path ]] || return 1
  parted --script $disk_path -- $(print_parted_commands) || return $?
  mkfs.vfat -n EFISYS -F 32 $(by_partlabel EFISYS) || return $?
  mkfs.ext4 -q -L linuxroot $(by_partlabel linuxroot) <<< y || return $?
  mkfs.ext4 -q -L linuxhome $(by_partlabel linuxhome) <<< y
}

mount_rootfs() {
  [[ -e $sysroot ]] && return 0
  local device
  device=$(blkid --label linuxroot)
  mount -m $device $sysroot
}

mount_efisys() {
  get_disk
  disk=$(< $installbase/disk)
  local device
  device=$(blkid --label EFISYS)
  [[ $device ]] || return 1
  mount --mkdir=0700 -o X-mount.mode=0700 $device $sysroot/boot/efi
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

stop() {
  touch /tmp/stop ; echo "OK"
}

# WARNING! This clears the partition table.
do_everything() {
  create_partitions || return $?
  mount_rootfs || return $?
  mount_efisys || return $?
  mount_other_things || return $?
  dnf_setup || return $?
  rootfs_install_packages || return $?
  rootfs_configure_hostname || return $?
  rootfs_configure_machine_id || return $?
  rootfs_configure_cmdline || return $?
  rootfs_configure_fstab || return $?
  rootfs_copy_kernel_install_conf || return $?
  rootfs_copy_root_config || return $?
  run_chrooted_post_sdboot || return $?
  rootfs_install_kernel || return $?
  run_chrooted_postinstall || return $?
  while [[ -f /tmp/stop ]]; do sleep 2; done
  reboot
}

try_again() {
  local next
  next=$(efibootmgr | sed -n -E 's/^BootCurrent:\s*(\S+)$/\1/p')
  [[ $next ]] && efibootmgr -n $next
  touch /tmp/fail
  tmux select-window -t1
}
