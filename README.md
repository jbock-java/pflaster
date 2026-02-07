### WARNING! This is an EXPERIMENTAL fedora installer.

| :warning: Running this may **erase all data** on your computer. |
|-----------------------------------------------------------------|

| :zap: You should only run this on a VM or a garbage computer. |
|---------------------------------------------------------------|

### How it started

See this thread: <https://discussion.fedoraproject.org/t/how-to-install-fedora-without-the-installer-manual-installation/156292>

### Prepare the installation

Run `make`. This should create `root.tgz`.

Now that you have `root.tgz`, start a http server. Here's an easy way to do this:

```
./serve
```

Write down the http address that this command prints out. For example: `http://192.168.178.22:3001/manual.cfg`

### Architectural overview

Our installer comes in the form of a kickstart file, which is executed by anaconda. Anaconda is the installer of the "Everything" fedora spin.

### Instructions for iPXE

Configure kernel and initrd (sample URLs, use a mirror close to you):

```
kernel https://ftp.halifax.rwth-aachen.de/fedora/linux/releases/43/Everything/x86_64/os/images/pxeboot/vmlinuz inst.ks=http://192.168.178.22:3001/manual.cfg
initrd https://ftp.halifax.rwth-aachen.de/fedora/linux/releases/43/Everything/x86_64/os/images/pxeboot/initrd.img
```

If you have secure boot enabled, you also need to configure a shim:

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
