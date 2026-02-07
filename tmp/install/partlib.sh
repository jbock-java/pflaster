[[ -v installbase ]] || source /tmp/install/common.sh

get_children() {
  [[ $1 ]] || return $(error "param: PATH")
  local kname
  kname=$(lsblk -n --filter "PATH == '$1'" -o KNAME)
  lsblk -n --filter "PKNAME == '$kname'" -o PATH
}

print_parted_commands() {
  local rootsize=16384
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
  local disk part disk_path uuid_linuxcrypt
  disk=$(get_disk) || return $(error "get_disk")
  disk_path=$(get_path $disk)
  [[ $disk_path ]] || return 1
  parted --script $disk_path -- $(print_parted_commands) || return $?
  mkfs.vfat -n EFISYS -F 32 $(by_partlabel EFISYS) || return $?
  mkfs.ext4 -q -L linuxroot $(by_partlabel linuxroot) <<< y || return $?
  mkfs.ext4 -q -L linuxhome $(by_partlabel linuxhome) <<< y || return $?
  echo -n temppass > /tmp/temppass
  chmod 600 /tmp/temppass
  cryptsetup luksFormat --batch-mode $(by_partlabel linuxcrypt) /tmp/temppass || return $(error "luksFormat")
  uuid_linuxcrypt=$(lsblk -n --filter "PATH == '$(by_partlabel linuxcrypt)'" -o UUID) || return $(error "uuid_linuxcrypt")
  cryptsetup luksOpen --batch-mode --key-file=/tmp/temppass $(by_partlabel linuxcrypt) luks-$uuid_linuxcrypt || return $(error "luksOpen")
  local pvcrypt linuxopt
  pvcrypt=$(get_children $(by_partlabel linuxcrypt))
  pvcreate $pvcrypt || return $(error "pvcreate")
  vgcreate vgcrypt $pvcrypt || return $(error "vgcreate")
  lvcreate -L 500M -n linuxopt vgcrypt || return $(error "lvcreate linuxopt")
  linuxopt=$(get_children $pvcrypt)
  mkfs.ext4 -q -L linuxopt $linuxopt <<< y || return $(error "ext4 linuxopt")
  sleep inf
}
