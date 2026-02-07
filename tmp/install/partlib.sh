[[ -v installbase ]] || source /tmp/install/common.sh

get_only_child() {
  [[ $1 ]] || return $(error "param: PATH")
  local kname children
  kname=$(lsblk -n --filter "PATH == '$1'" -o KNAME)
  children=$(lsblk -n --filter "PKNAME == '$kname'" -o PATH | tr '\n' ' ')
  children=${children% }
  [[ $children = "${children// /}" ]] || return $(error "more than one child")
  echo $children
}

print_parted_commands() {
  local rootsize=8192
  local homesize=4096
  local cryptsize=4096
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
  echo "mkpart linuxcrypt ext4 ${pos}MiB $(( pos + cryptsize ))MiB"
  (( pos += cryptsize ))
}

# WARNING! This clears the partition table.
create_partitions() {
  local disk part linuxcrypt luksroot
  disk=$(get_disk) || return $(error "get_disk")
  parted --script $disk -- $(print_parted_commands) || return $(error "parted")
  mkfs.vfat -n EFISYS -F 32 $(by_partlabel EFISYS) || return $(error "mkfs efisys")
  mkfs.ext4 -q -L linuxroot $(by_partlabel linuxroot) <<< y || return $(error "mkfs linuxroot")
  mkfs.ext4 -q -L linuxhome $(by_partlabel linuxhome) <<< y || return $(error "mkfs linuxhome")
  echo -n temppass > /tmp/temppass
  chmod 600 /tmp/temppass
  linuxcrypt=$(by_partlabel linuxcrypt)
  cryptsetup luksFormat --batch-mode $linuxcrypt /tmp/temppass || return $(error "luksFormat")
  cryptsetup luksOpen --batch-mode --key-file=/tmp/temppass $linuxcrypt lr || return $(error "luksOpen")
  luksroot=$(get_only_child $linuxcrypt) || return $(error "get_only_child")
  pvcreate $luksroot || return $(error "pvcreate")
  vgcreate lr $luksroot || return $(error "vgcreate")
  lvcreate -L 500M -n opt lr || return $(error "lvcreate opt")
  mkfs.ext4 -q -L lr-opt /dev/mapper/lr-opt <<< y || return $(error "ext4 opt")
  echo "create_partitions: going to sleep"
  sleep inf
}
