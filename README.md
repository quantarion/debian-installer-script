# debian-installer-script

**Warning:** This script will most certainly destroy any data you might have on any drive in the computer, and only potentially install Debian. Do not use unless you know exactly what you're doing.

This is a rewrite of the Debian installation script from ODIN, [Opinionated Debian Installer](https://github.com/r0b0/debian-installer). It started as a minor bug fix, but ended up as a complete rewrite, bearing very little resemblance to the original script.

At this time, it installs Debian Trixie with LUKS, BTRFS, Dracut, systemd-boot, and TPM 2.0 root unlock. Edit the script, execute as root with `./my_installer.sh host`, and hope for the best.