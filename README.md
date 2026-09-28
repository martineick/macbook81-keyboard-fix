# MacBook8,1 keyboard fix

Makes the built-in keyboard and trackpad of the **12-inch MacBook (Early 2015, MacBook8,1)** reliable on Linux: Ubuntu, Fedora, and most other distros.

It fixes two problems:

- **Dead on some boots, at random.** The kernel log fills with `applespi ... SPI transfer timed out` / `Error reading from device: -110`.
- **Dead after suspend.** The keyboard works until the lid is closed once, then stays dead until you reboot.

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/martineick/macbook81-keyboard-fix/main/macbook81-keyboard-fix.sh
sudo bash macbook81-keyboard-fix.sh --dry-run
sudo bash macbook81-keyboard-fix.sh
```

Reboot, then confirm that it's active:

```bash
bash macbook81-keyboard-fix.sh check
```

Running it again is safe. To undo everything it changed:

```bash
sudo bash macbook81-keyboard-fix.sh revert
```

## If the keyboard is dead on first boot

The keyboard always works in the GRUB menu. If it's dead after booting a fresh install:

1. Reboot. On Fedora, hold Esc or Shift to show the menu.
2. Press `e` on the boot entry.
3. Add `mem_sleep_default=s2idle modprobe.blacklist=dw_dmac_pci` to the end of the line starting with `linux`.
4. Boot with Ctrl-X or F10, then run the script.

## Why this happens

The keyboard and trackpad are on an Intel SPI bus (the `applespi` driver).

1. If the `dw_dmac_pci` DMA driver loads before the SPI controller driver, the controller uses DMA. On this machine every DMA transfer times out. Blocking `dw_dmac_pci` makes the controller use PIO mode, which works. A kernel patch series from July 2026 forces PIO on this model; until your kernel has it, the blacklist is needed.
2. S3 ("deep") sleep wipes the SPI controller's settings, and they aren't restored on wake. s2idle keeps the controller powered.

The fix is two kernel arguments: `mem_sleep_default=s2idle modprobe.blacklist=dw_dmac_pci`.

## What the script changes

It checks what your system has and updates each of these that exists:

- **GRUB:** a drop-in in `/etc/default/grub.d/` on Debian/Ubuntu. On other distros, a marked block in `/etc/default/grub`.
- **Fedora boot entries:** through `grubby`, plus `/etc/kernel/cmdline` so new kernels get the arguments too.
- **systemd-boot:** `/etc/kernel/cmdline`.
- **Module blacklist:** `/etc/modprobe.d/90-macbook81-keyboard-fix.conf`.
- **Suspend mode:** `MemorySleepMode=s2idle` in `/etc/systemd/sleep.conf.d/` (systemd 256 or newer).
- **Initramfs:** dracut, initramfs-tools or mkinitcpio. It keeps `dw_dmac_pci` out of the image, and adds the keyboard drivers if your disk is encrypted with LUKS, so you can type the passphrase. Then it rebuilds the image.

Files it edits but doesn't own get a `.bak-macbook81-keyboard-fix` backup first.

## Status

- **The fix:** confirmed on Kubuntu 26.04 with kernel 7.0.
- **The script's distro handling:** tested against simulated Ubuntu (dracut), Fedora, Arch and systemd-boot layouts, not yet on real installs of those distros.

Run with `--dry-run` first on a new distro.
