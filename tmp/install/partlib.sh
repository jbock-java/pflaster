[[ -v installbase ]] || source /tmp/install/common.sh

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

print_parted_commands() {
  local disksize
  disksize=$(get_disksize)
  local efisize=2044
  local pvrootsize=$(( disksize - efisize - 32 ))
  local pos=4
  echo "mklabel gpt"
  echo "mkpart EFISYS fat32 ${pos}MiB $(( pos + efisize ))MiB"
  (( pos += efisize ))
  echo "set 1 esp on"
  echo "mkpart pvroot ext4 ${pos}MiB $(( pos + pvrootsize ))MiB"
  (( pos += pvrootsize ))
}

# WARNING! This clears the partition table.
create_partitions() {
  local disk part pvroot luksroot
  disk=$(get_disk) || return $(error "get_disk")
  parted --script --align optimal $disk -- $(print_parted_commands) || return $(error "parted")
  mkfs.vfat -n EFISYS -F 32 $(by_partlabel EFISYS) || return $(error "mkfs efisys")
  echo -n temppass > /tmp/temppass
  chmod 600 /tmp/temppass
  pvroot=$(by_partlabel pvroot)
  cryptsetup luksFormat --batch-mode $pvroot /tmp/temppass || return $(error "luksFormat")
  cryptsetup luksOpen --batch-mode --key-file=/tmp/temppass $pvroot luks || return $(error "luksOpen")
  cryptsetup config $pvroot --label pvroot || return $(error "cryptsetup config")
  luksroot=$(get_only_child $pvroot) || return $(error "get_only_child")
  pvcreate $luksroot || return $(error "pvcreate")
  vgcreate luks $luksroot || return $(error "vgcreate")
  lvcreate -L 8192M -n root luks || return $(error "lvcreate root")
  lvcreate -L 2048M -n home luks || return $(error "lvcreate home")
  mkfs.ext4 -q -L luks-root /dev/mapper/luks-root <<< y || return $(error "ext4 root")
  mkfs.ext4 -q -L luks-home /dev/mapper/luks-home <<< y || return $(error "ext4 home")
}
