# vm-provisioner

Interactive script that builds a VMware Workstation VM with a fully
unattended OS install baked in - pick an OS, drop in the ISO, answer a few
questions, and it installs itself with no further clicking.

## Supported OS

| | OS |
|---|---|
| <img src="assets/ubuntu-logo.png" width="32"> | **Ubuntu Server 26.04 LTS** |
| <img src="assets/kali-logo.svg" width="32"> | **Kali Linux (XFCE) netinst** |

## Usage

1. Run it:
   ```bash
   ./provision.sh
   ```
2. Pick an OS from the list it shows you.
3. It tells you exactly where to put the ISO (e.g. `isos/ubuntu-server.iso`)
   - drop it there and press Enter.
4. Answer a few prompts: VM name, hostname, username, password, SSH key,
   and how much CPU/RAM to use during install vs. afterward.
5. Toggle any optional extras (skip the GRUB menu, root SSH login, SSH
   password login, extra packages) or just press Enter to accept defaults.
6. Press Enter to start. It builds the install ISO, creates the VM, and
   installs the OS completely unattended - no need to click through the
   installer yourself.

When it's done you get a ready-to-use VM with the resources shrunk back
down for everyday use, and the SSH command to connect to it.

See `ARCHITECTURE.md` for how it works under the hood and how to add a new OS.
