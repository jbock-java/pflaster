# bruder

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

You need the fedora "server dvd" iso.
Here's a sample download url: <https://ftp.halifax.rwth-aachen.de/fedora/linux/releases/43/Server/x86_64/iso/Fedora-Server-dvd-x86_64-43-1.6.iso>

If you use virtualbox or some other VM, then you can boot this iso file directly.
Otherwise you need to create an installation medium. For example, a usb drive.

When you boot the iso, you will see a black "grub menu".
Press up or down arrow key to cancel the timeout.
Then, navigate to the first option "Install Fedora".
Press "e" to edit the installer's kernel command line options.

At the end of the relevant line, add an option `inst.ks=http://192.168.178.22:3000/manual.cfg`,
assuming your http server runs on `192.168.178.22`.

### TODO

work in progress...
