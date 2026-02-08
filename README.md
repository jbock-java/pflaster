### WARNING! This is an EXPERIMENTAL fedora installer.

| :warning: Running this may :rotating_light: **erase all your data** :rotating_light: :ambulance: :ambulance: |
|--------------------------------------------------------------------------------------------------------------|

| :zap: You should only run this on a VM or garbage computer! :zap: |
|-------------------------------------------------------------------|

### Goals

1. TODO: The installed system should behave like any other fedora installation.
2. [support LUKS devices that are unlocked outside the installer](https://bugzilla.redhat.com/show_bug.cgi?id=2019455)
3. TODO: Unlocking via tpm should work out of the box.
4. systemd-boot by default
5. TODO: RAID, non-ext4 filesystems. PRs welcome.

### Architectural overview

* We use the "Everything" fedora spin.
* Anaconda is used, but only as an entry point. In kickstart terms: the entire installation happens in "%pre".
* The installer is written in bash.
* Packages are installed via dnf.

### Partitioning

This is the default partitioning:

```
[core@box ~]$ lsblk -i -o NAME,TYPE,FSTYPE,LABEL,SIZE,MOUNTPOINTS
NAME            TYPE  FSTYPE      LABEL      SIZE MOUNTPOINTS
sda             disk                        25.9G
|-sda1          part  vfat        EFISYS       2G /boot/efi
`-sda2          part  crypto_LUKS pvroot    23.9G
  `-luks        crypt LVM2_member           23.9G
    |-luks-root lvm   ext4        luks-root    8G /
    `-luks-home lvm   ext4        luks-home    2G /home
zram0           disk  swap        zram0        8G [SWAP]
```

* Everything but the efi partition (sda1) is encrypted.
* When unlocked, the crypted partition (sda2) contains an lvm volume group.
* You can add more lvm partitions later. For example, a second swap device.
* The installer creates the lvm partitions with minimal default sizes. You can extend them later.
* Currently, the installer sets a LUKS key "temppass". You may want to change this after installation.
* TODO: If a partition labeled "pvroot" exists, the installer should prompt for the LUKS key. The lvm partition labeled "luks-home" will be preserved.
* TODO: Allow package configuration.
* TODO: Configurable user creation and root pw.

### How it started

See this thread: <https://discussion.fedoraproject.org/t/how-to-install-fedora-without-the-installer-manual-installation/156292>

### Prepare the installation

Run `make`. This should create `root.tgz`.

Now that you have `root.tgz`, start a server. Here's an easy way to do this:

```
./serve
```

Write down the http address that is printed, and append "manual.cfg". For example: `http://192.168.178.22:3001/manual.cfg`

### Instructions for iPXE

Configure kernel and initrd (sample URLs, use a mirror close to you):

```
kernel https://ftp.halifax.rwth-aachen.de/fedora/linux/releases/43/Everything/x86_64/os/images/pxeboot/vmlinuz inst.ks=http://192.168.178.22:3001/manual.cfg
initrd https://ftp.halifax.rwth-aachen.de/fedora/linux/releases/43/Everything/x86_64/os/images/pxeboot/initrd.img
```

If you have secure boot enabled ([n.b.: doesn't work](https://forge.fedoraproject.org/releng/tickets/issues/10765)), you also need to configure a shim:

```
shim https://ftp.halifax.rwth-aachen.de/fedora/linux/releases/43/Everything/x86_64/os/EFI/BOOT/BOOTX64.EFI
```

When everything is configured, start the installation:

```
boot
```

Read more about iPXE: [iPXE commands](https://ipxe.org/cmd), [iPXE installation and EFI](https://doc.rogerwhittaker.org.uk/ipxe-installation-and-EFI/).

### Downloading the iso

If you do not use iPXE, you will need to download an "iso file".
Here's a sample download url: <https://ftp.halifax.rwth-aachen.de/fedora/linux/releases/43/Everything/x86_64/iso/Fedora-Everything-netinst-x86_64-43-1.6.iso>

### VM instructions

If you use virtualbox or some other VM, you should be able to boot the iso file directly.

### Installation medium instructions

If you do not use iPXE or a VM, you may need to create an "installation medium" from the iso file. For example, a usb drive. There are plenty of tutorials for this on the internet.

When you boot the installation medium, you will see a black "grub menu".
Press up or down arrow key to cancel the timeout.
Then, navigate to the first option "Install Fedora".
Press "e" to edit the installer's kernel command line options.

At the end of the line starting with "linux", add an option `inst.ks=http://192.168.178.22:3001/manual.cfg`,
assuming your http server runs on `192.168.178.22`.
