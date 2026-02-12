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
  local disksize efizsize
  disksize=$(get_disksize)
  efisize=$(get_config .defaultsize.efisys)
  efisize=${efisize:-2044}
  local pvrootsize=$(( disksize - efisize - 32 ))
  local pos=4
  echo "mklabel gpt"
  echo "mkpart EFISYS fat32 ${pos}MiB $(( pos + efisize ))MiB"
  (( pos += efisize ))
  echo "set 1 esp on"
  echo "mkpart pvroot ext4 ${pos}MiB $(( pos + pvrootsize ))MiB"
  (( pos += pvrootsize ))
}

gen_new_lukskey() {
  local reply0 reply1
  read -rsp "Choose lukskey: " reply0
  echo
  [[ -n $reply0 ]] || return 1
  read -rsp "Confirm lukskey: " reply1
  echo
  [[ $reply0 = "$reply1" ]] || return 1
  echo -n "$reply0" > $installbase/lukskey
}

create_partitions() {
  local disk part pvroot luksroot lukskey rootsize homesize
  lukskey=$(get_config .lukskey)
  if [[ $lukskey ]]; then
    echo -n "$lukskey" > $installbase/lukskey
  else
    if has_modifier "noask"; then
      return $(error "in noask mode, lukskey must be configured")
    fi
    while true; do
      gen_new_lukskey && break
    done
  fi
  disk=$(get_disk) || return $(error "get_disk")
  parted --script --align optimal $disk -- $(print_parted_commands) || return $(error "parted")
  mkfs.vfat -n EFISYS -F 32 $(by_partlabel EFISYS) || return $(error "mkfs vfat")
  pvroot=$(by_partlabel pvroot)
  chmod 600 $installbase/lukskey
  cryptsetup luksFormat --force-password --batch-mode $pvroot $installbase/lukskey || return $(error "crypt format")
  cryptsetup luksOpen --batch-mode --key-file=$installbase/lukskey $pvroot luks || return $(error "crypt open")
  cryptsetup config $pvroot --label pvroot || return $(error "crypt label")
  luksroot=$(get_only_child $pvroot) || return $(error "find luksroot")
  pvcreate $luksroot || return $(error "pvcreate")
  vgcreate luks $luksroot || return $(error "vgcreate")
  rootsize=$(get_config .defaultsize.root)
  homesize=$(get_config .defaultsize.home)
  lvcreate -L ${rootsize:-8192}M -n root luks || return $(error "lvcreate root")
  lvcreate -L ${homesize:-2048}M -n home luks || return $(error "lvcreate home")
  mkfs.ext4 -q -L luks-root /dev/mapper/luks-root <<< y || return $(error "ext4 root")
  mkfs.ext4 -q -L luks-home /dev/mapper/luks-home <<< y || return $(error "ext4 home")
}

get_existing_lukskey() {
  local REPLY pvroot
  pvroot=$(blkid --label pvroot 2> /dev/null) || return 1
  echo "Found pvroot: $pvroot"
  if has_modifier "noask"; then
    REPLY=$(get_config .lukskey)
    if [[ -z $REPLY ]]; then
      return $(error "in noask mode, lukskey must be configured")
    fi
  else
    read -rsp "Enter lukskey, or leave empty to wipe: "
    echo
  fi
  if [[ -z $REPLY ]]; then
    return 125
  fi
  echo -n "$REPLY" > $installbase/lukskey
  chmod 600 $installbase/lukskey
  cryptsetup luksOpen -q --disable-external-tokens --key-file $installbase/lukskey --test-passphrase $pvroot
}

unlock_pvroot() {
  [[ -f $installbase/lukskey ]] || return 1
  local pvroot luks_root efisys
  efisys=$(blkid --label EFISYS) || return $(error "no such label: EFISYS")
  pvroot=$(blkid --label pvroot 2> /dev/null) || return 1
  cryptsetup luksOpen -q --disable-external-tokens --key-file $installbase/lukskey $pvroot luks || return
  vgchange -ay
  luksroot=$(blkid --label luks-root) || return $(error "no such label: luks-root")
  blkid --label luks-home || return $(error "no such label: luks-home")
  mkfs.ext4 -q -L luks-root $luksroot <<< y || return $(error "mkfs luks-root")
  mkfs.vfat -n EFISYS -F 32 $efisys || return $(error "mkfs efisys")
}

prepare_partitions() {
  if ! has_modifier "always-wipe" && blkid --label pvroot &> /dev/null; then
    while true; do
      get_existing_lukskey
      case $? in
        125) break ;;
        0)
          unlock_pvroot
          return
          ;;
      esac
    done
  fi
  if ! has_modifier "noask"; then
    local REPLY
    while true; do
      read -rp "Erase all data on $(get_disk)? [y/N] "
      [[ $REPLY =~ [yY] ]] && break
      [[ $REPLY =~ [nN] ]] && { echo "I sleep." ; sleep inf ; }
    done
  fi
  create_partitions
}
