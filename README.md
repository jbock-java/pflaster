# Pflaster

Fedora manual installation

### Context

See this thread: <https://discussion.fedoraproject.org/t/how-to-install-fedora-without-the-installer-manual-installation/156292>

### Installing fedora

Run `make`. This should create `root.tgz`.

Now that you have `root.tgz`, start a http server. Here's an easy way to do this:

```
./serve
```

Write down the http address that this command prints out.

You can use the fedora "everything netinstall" iso.
Here's a sample download url: <https://ftp.halifax.rwth-aachen.de/fedora/linux/releases/43/Everything/x86_64/iso/Fedora-Everything-netinst-x86_64-43-1.6.iso>

If you use ipxe, you don't need the iso, but these lines in your ipxe config:

* kernel <https://ftp.halifax.rwth-aachen.de/fedora/linux/releases/43/Everything/x86_64/os/images/pxeboot/vmlinuz>
* initrd <https://ftp.halifax.rwth-aachen.de/fedora/linux/releases/43/Everything/x86_64/os/images/pxeboot/initrd.img>

If you have secure boot enabled, you also need this one:

* shim <https://ftp.halifax.rwth-aachen.de/fedora/linux/releases/43/Everything/x86_64/os/EFI/BOOT/BOOTX64.EFI>

If you use virtualbox or some other VM, then you can boot the iso file directly.

Otherwise you need to create an installation medium. For example, a usb drive.

When you boot from the iso, you will see a black "grub menu".
Press up or down arrow key to cancel the timeout.
Then, navigate to the first option "Install Fedora".
Press "e" to edit the installer's kernel command line options.

At the end of the line starting with "linux", add an option `inst.ks=http://192.168.178.22:3001/manual.cfg`,
assuming your http server runs on `192.168.178.22`.
