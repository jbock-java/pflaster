installbase=/tmp/install
sysroot=/mnt/sysroot

by_partlabel() {
  blkid -o device -t PARTLABEL=$1
}

get_path() {
  lsblk -n --filter "KNAME=='$1'" -o PATH
}

get_parts() {
  lsblk -n --filter "PKNAME=='$1'" -o KNAME
}

configure_repos() {
  sed -i "s|^enabled=.*|enabled=0|" /etc/yum.repos.d/*.repo
  sed -i -E \
    -e 's/^(\[.*\])$/\1\nsslverify=0/' \
    -e "s|^countme=.*|countme=0|" \
    -e "s|^enabled=.*|enabled=1|" \
    /etc/yum.repos.d/fedora.repo
}

dnf_setup() {
  [[ -e /etc/yum.repos.d ]] && return 0
  ln -f -s -T /etc/anaconda.repos.d /etc/yum.repos.d
  configure_repos
}

os_release() {
  sed -n -E 's/^VERSION_ID=(\S+)/\1/p' /etc/os-release
}

dnf_install() {
  if type rpm 2> /dev/null && rpm --quiet -q $1; then return 0; fi
  dnf4 -y install --nogpgcheck --releasever=$(os_release) "$@"
}

get_disks() {
  lsblk -n --filter "TYPE=='disk' && RM==0 && MOUNTPOINT!='[SWAP]'" -o KNAME | tr '\n' ' '
}

get_disk() {
  if [[ -f $installbase/disk ]]; then
    cat $installbase/disk
    return 0
  fi
  local disks REPLY
  disks=$(get_disks)
  disks=${disks% }
  if [[ ${disks/ /} = "$disks" ]]; then
    echo $disks | tee $installbase/disk
  else
    lsblk
    read -r -p "Please choose disk for installation [${disks// /|}]: "
    echo $REPLY | tee $installbase/disk
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

mount_sysroot() {
  [[ -e $sysroot ]] && return 0
  mkdir -p $sysroot
  local device
  device=$(blkid --label linuxroot)
  mount $device $sysroot
}

install_sdboot() {
  local device
  device=$(blkid --label EFISYS)
  mkdir -p $sysroot/boot/efi
  disk=$(< $installbase/disk)
  echo "disk: $disk"
  #mkdir -p /new_system/esp
  #mount /dev/sda2 /new_system/esp
  #mkdir -p /new_system/esp/sd-boot/
  #cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /new_system/esp/sd-boot/
  #efibootmgr -c -d /dev/sda -p 2 -l "\sd-boot\systemd-bootx64.efi" -L "fedora sd-boot"
}

rootfs_configure_hostname() {
  mkdir -p $sysroot/etc
  # todo: take hostname from cmdline, or ask the user
  echo "box" > $sysroot/etc/hostname
}

rootfs_configure_machine_id() {
  mkdir -p $sysroot/etc
  head -c 16 /dev/urandom | od -A n -t x1 | sed 's/ //g' > $sysroot/etc/machine-id
}

rootfs_copy_kernel_install_conf() {
  mkdir -p $sysroot/etc/kernel
  cp $installbase/install.conf $sysroot/etc/kernel/install.conf
}

rootfs_copy_postinstall() {
  mkdir -p $sysroot/root
  cp $installbase/postinstall $sysroot/root/postinstall
}

install_rootfs() {
  [[ -e $sysroot ]] || return 1
  rsync \
     -pogAXtlHrDx \
     --stats \
     --info=flist2,name,progress2 \
     --no-inc-recursive \
     --exclude /dev/ \
     --exclude /proc/ \
     --exclude "/tmp/*" \
     --exclude /sys/ \
     --exclude /run/ \
     --exclude "/boot/*rescue*" \
     --exclude /boot/loader/ \
     --exclude /boot/efi/ \
     --exclude /etc/machine-id \
     --exclude /etc/machine-info \
     /run/rootfsbase/ \
     $sysroot
}

install_tools() {
  local deps
  deps=(
    systemd-boot-unsigned
    rpm
    vim-enhanced
  )
  dnf_setup
  dnf_install ${deps[@]}
}

# WARNING! This clears the partitions table.
do_everything() {
  install_tools || return $?
  create_partitions || return $?
  #todo: install sdboot
  mount_sysroot || return $?
  install_rootfs || return $?
  rootfs_configure_hostname || return $?
  rootfs_configure_machine_id || return $?
  rootfs_copy_kernel_install_conf || return $?
  rootfs_copy_postinstall || return $?
  chroot $sysroot /root/postinstall
}

try_again() {
  local next
  next=$(efibootmgr | sed -n -E 's/^BootCurrent:\s*(\S+)$/\1/p')
  [[ $next ]] && efibootmgr -n $next
  touch /tmp/fail
  tmux select-window -t1
}
