get_path() {
  lsblk -n --filter "KNAME=='$1'" -o PATH
}

get_parts() {
  lsblk -n --filter "PKNAME=='$1'" -o KNAME
}

dnf_setup() {
  [[ -e /etc/yum.repos.d ]] && return 0
  ln -f -s -T /etc/anaconda.repos.d /etc/yum.repos.d
}

os_release() {
  sed -n -E 's/^VERSION_ID=(\S+)/\1/p' /etc/os-release
}

dnf_install() {
  dnf4 -y install --nogpgcheck --releasever=$(os_release) "$@"
}

get_disk() {
  lsblk -n --filter "TYPE=='disk' && MOUNTPOINT!='[SWAP]'" -o KNAME
}

print_create_esp() {
  echo "mklabel gpt"
  echo "mkpart efisys fat32 1MiB 1025MiB"
  echo "set 1 esp on"
}

# This clears the partition table. I hope you know what you're doing.
create_esp() {
  local disk part
  disk=$(get_disk)
  parted -s $(get_path $disk) -- $(print_create_esp)
  part=$(get_parts $device)
  [[ $part = *$'\n'* ]] || {
    echo "expecting only one partition on $device"
  }
  mkfs.vfat -F 32 $(get_path $part)
}

install_sdboot() {
  local disk
  disk=$(get_disk)
  echo "disk: $disk"
  #mkdir -p /new_system/esp
  #mount /dev/sda2 /new_system/esp
  #mkdir -p /new_system/esp/sd-boot/
  #cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /new_system/esp/sd-boot/
  #efibootmgr -c -d /dev/sda -p 2 -l "\sd-boot\systemd-bootx64.efi" -L "fedora sd-boot"
}

populate_system() {
  mkdir -p /mnt/sysroot
  #mount /dev/sda1 /mnt/sysroot
  #rsync \
  #   -pogAXtlHrDx \
  #   --stats \
  #   --info=flist2,name,progress2 \
  #   --no-inc-recursive \
  #   --exclude /dev/ \
  #   --exclude /proc/
  #   --exclude "/tmp/*" \
  #   --exclude /sys/ \
  #   --exclude /run/ \
  #   --exclude "/boot/*rescue*" \
  #   --exclude /boot/loader/ \
  #   --exclude /boot/efi/ \
  #   --exclude /etc/machine-id \
  #   --exclude /etc/machine-info \
  #   /run/rootfsbase/ \
  #   /mnt/sysroot
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

try_again() {
  local next
  next=$(efibootmgr | sed -n -E 's/^BootCurrent:\s*(\S+)$/\1/p')
  [[ $next ]] && efibootmgr -n $next
  touch /tmp/fail
  tmux select-window -t1
}
