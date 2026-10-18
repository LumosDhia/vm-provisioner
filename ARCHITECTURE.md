# Architecture notes

Technical details for maintaining/extending `provision.sh`. See `README.md`
for plain usage.

## Layout

```
provision.sh           main interactive script
lib/vnc_send_key.py     dependency-free VNC (RFB) key-sender, pure stdlib
isos/                   drop source install ISOs here (gitignored)
configs/<type>/         one folder per supported machine type
  machine.conf           metadata: ISO filename convention, default specs,
                          GRUB anchor, INSTALL_METHOD, boot-style details
  user-data.template.yaml  cloud-init autoinstall template (cloud-init types)
  meta-data.template       cloud-init meta-data template (cloud-init types)
  custom.preseed.template  Debian Installer preseed template (debian-preseed types)
```

## Install methods

Two install methods are supported, picked per machine type via `machine.conf`'s
`INSTALL_METHOD`:

- **`cloud-init`** - Ubuntu's Subiquity autoinstall (cloud-init YAML), e.g. `ubuntu-server`.
- **`debian-preseed`** - Debian Installer preseeding, e.g. `kali-linux`. Kali's
  own ISO already ships a preseed (`simple-cdd/kali.preseed`) covering
  apt/package policy but leaving out partitioning, the user account, hostname
  and timezone; this provisioner layers its own `custom` profile on top via
  simple-cdd's comma-separated profile list (`simple-cdd/profiles=kali,custom`)
  instead of touching Kali's own file.

Both methods share the same GRUB-insertion logic and the same post-install
SSH toggle step - only the autoinstall config format and where it's written
into the extracted ISO tree differ.

## ISO boot styles

`machine.conf`'s `ISO_BOOT_STYLE` picks how the repacked ISO stays bootable
(BIOS + UEFI hybrid):

- **`grub2`** (Ubuntu) - grub-mkrescue built the source ISO: grub2 owns the
  BIOS boot image and the hybrid MBR, and the UEFI El Torito image is
  "hidden" (embedded with no visible ISO9660 path), so the provisioner dd's
  it out by LBA/size (`extract_efi_image`) and references it as an appended
  GPT partition.
- **`isolinux`** (Kali/Debian) - isolinux owns BIOS boot, the UEFI image is a
  real visible file already (`boot/grub/efi.img`) referenced directly, and
  the hybrid MBR boot code is reused from the source ISO itself (dd'd out of
  its first 432 bytes) rather than requiring the separate isolinux/syslinux
  package for `isohdpfx.bin`.

## Unattended boot confirmation (VNC)

Some installer ISOs set no GRUB timeout at all anywhere in `grub.cfg` (Kali),
so GRUB defaults to waiting forever for a keypress - a plain `set timeout=N`
substitution does nothing if there's no existing timeout line to replace.
`build_autoinstall_iso` always prepends its own `set timeout_style=menu` /
`set timeout=5` at the very top of `grub.cfg` as a fallback, but the primary
mechanism is `confirm_boot_menu`: `create_vmx` enables VMware's VNC server on
the VM (bound to `127.0.0.1`, no password, a fresh port per VM), and right
after power-on, `lib/vnc_send_key.py` sends a real Enter keystroke over the
RFB protocol to confirm the already-highlighted autoinstall entry. This is
the same technique HashiCorp Packer's `vmware-iso` builder uses (VNC +
`boot_command`). VNC is disabled again in `finalize_vm` once the VM is done.

## Known gotchas (already handled, documented so they don't get "fixed" back)

- **GRUB kernel cmdline backslash-escaping.** GRUB needs a literal `\;`
  before `ds=nocloud;s=...` (Ubuntu's cloud-init datasource arg) - `;` is a
  command separator in grub.cfg otherwise. Both `awk -v` and GNU sed's
  handling of a literal `\;` token are unreliable (awk's `-v` escape
  processing silently drops the backslash; GNU sed specifically eats `\;` in
  replacement text, though it leaves e.g. `\Y` alone - a documented quirk).
  The backslash is built at runtime via `sprintf("%c",92)` inside the awk
  script instead of ever being written as a `\;` token anywhere.
- **VM name sanitization.** Use `printf '%s' "$VM_NAME"` into the `tr`
  pipeline, not `echo` - `echo`'s trailing newline gets transliterated by
  `tr -cs 'a-z0-9-' '-'` into a trailing `-` on the VM name.
- **Debian Installer's language question is asked before `early_command`
  runs** - which is what loads simple-cdd's own preseed profiles (including
  our `custom` one). So `debian-installer/locale` set *inside*
  `custom.preseed.template` is too late; the installer prompts for language
  anyway despite `auto=true priority=critical`. Fix: pass `locale=` and
  `keymap=` directly as kernel boot parameters (Debian Installer's dedicated
  early shortcuts for exactly this, parsed before any preseed file loads) -
  see `AUTOINSTALL_KERNEL_ARGS` in `configs/kali-linux/machine.conf`.

## Adding a new machine type

Copy the closest existing `configs/<type>/` folder and adjust `machine.conf`
plus its template(s) for the new OS/installer. The GRUB-patch logic assumes
a grub2 BIOS+UEFI hybrid ISO (as Ubuntu/Debian/Kali installers use) -
`machine.conf`'s `GRUB_ANCHOR_LINE` must match an existing `menuentry` line
in that ISO's `boot/grub/grub.cfg` exactly. Check `EFI_IMAGE_HIDDEN` and
`ISO_BOOT_STYLE` against the real ISO (`xorriso -indev <iso>
-report_el_torito plain` shows both boot images' paths/LBAs) rather than
assuming - Ubuntu and Kali differ on both.

## Requirements

Needs `xorriso`, `vmware-vdiskmanager`, `vmrun`, `mkpasswd` (whois package),
`python3`, and the usual `awk`/`sed`/`dd`/`ssh`/`file`.

VMs are created under `~/.vmware/Mchines/<vm-name>/` (override with
`VM_BASE_DIR`). Built ISOs/work files go under `./.work/<vm-name>/`
(override with `WORK_ROOT`).
