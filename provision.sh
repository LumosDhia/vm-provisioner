#!/usr/bin/env bash
# vm-provisioner: interactive VMware Workstation VM builder with an
# unattended install (cloud-init autoinstall or Debian preseed, depending on
# machine type) baked into a repacked ISO.
#
# Layout:
#   provision.sh          - this script
#   isos/                 - drop source ISOs here, named per machine.conf's ISO_FILENAME
#   configs/<type>/        - one folder per supported machine type:
#                             machine.conf + its install-method templates (see README)
#
# Usage: ./provision.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO_DIR="$SCRIPT_DIR/isos"
CONFIGS_DIR="$SCRIPT_DIR/configs"
VM_BASE_DIR="${VM_BASE_DIR:-$HOME/.vmware/Mchines}"
WORK_ROOT="${WORK_ROOT:-$SCRIPT_DIR/.work}"

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_bin() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"
}

# ---------------------------------------------------------------------------
# Step 1: pick a machine type
# ---------------------------------------------------------------------------

list_machine_types() {
    local i=1 dir
    MACHINE_DIRS=()
    for dir in "$CONFIGS_DIR"/*/; do
        [ -f "${dir}machine.conf" ] || continue
        MACHINE_DIRS+=("$dir")
        # shellcheck disable=SC1090
        ( source "${dir}machine.conf"; printf '  %d) %s\n' "$i" "$MACHINE_NAME" )
        i=$((i + 1))
    done
}

choose_machine_type() {
    say "Supported machine types"
    list_machine_types
    [ "${#MACHINE_DIRS[@]}" -gt 0 ] || die "No machine types found under $CONFIGS_DIR"

    local choice
    while true; do
        read -rp "Pick a machine type [1-${#MACHINE_DIRS[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#MACHINE_DIRS[@]}" ]; then
            MACHINE_DIR="${MACHINE_DIRS[$((choice - 1))]}"
            break
        fi
        warn "Invalid choice."
    done

    # shellcheck disable=SC1090
    source "${MACHINE_DIR}machine.conf"
}

# ---------------------------------------------------------------------------
# Step 2: ISO placement
# ---------------------------------------------------------------------------

wait_for_iso() {
    local iso_path="$ISO_DIR/$ISO_FILENAME"
    say "ISO required for $MACHINE_NAME"
    echo "  Place the installer ISO at:"
    echo "    $iso_path"
    echo "  (naming convention: $ISO_FILENAME)"
    while [ ! -f "$iso_path" ]; do
        read -rp "Press Enter once the file is there (or Ctrl+C to abort): " _
    done
    SRC_ISO="$iso_path"
    say "Found ISO: $SRC_ISO ($(du -h "$SRC_ISO" | cut -f1))"
}

# ---------------------------------------------------------------------------
# Step 3: resources
# ---------------------------------------------------------------------------

ask_resources() {
    say "Resources"
    read -rp "VM name [${MACHINE_NAME// /-}]: " VM_NAME
    VM_NAME="${VM_NAME:-${MACHINE_NAME// /-}}"
    # printf, not echo: echo's trailing newline would otherwise get
    # transliterated by tr into a trailing '-'.
    VM_NAME="$(printf '%s' "$VM_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-')"
    VM_NAME="${VM_NAME%-}"

    read -rp "Hostname [$VM_NAME]: " HOSTNAME_IN
    HOSTNAME_IN="${HOSTNAME_IN:-$VM_NAME}"

    read -rp "Username: " USERNAME_IN
    [ -n "$USERNAME_IN" ] || die "Username cannot be empty."

    read -rp "Real name [$USERNAME_IN]: " REALNAME_IN
    REALNAME_IN="${REALNAME_IN:-$USERNAME_IN}"

    read -rsp "Password (used for this user and root): " PASSWORD_IN
    echo
    [ -n "$PASSWORD_IN" ] || die "Password cannot be empty."

    local default_key="$HOME/.ssh/id_ed25519.pub"
    read -rp "SSH public key file [$default_key]: " SSH_KEY_FILE
    SSH_KEY_FILE="${SSH_KEY_FILE:-$default_key}"
    [ -f "$SSH_KEY_FILE" ] || die "SSH public key not found: $SSH_KEY_FILE"
    SSH_PUBKEY="$(cat "$SSH_KEY_FILE")"

    echo
    echo "Install-time resources (used only during the unattended install, for speed):"
    read -rp "  vCPUs [$DEFAULT_INSTALL_VCPUS]: " INSTALL_VCPUS
    INSTALL_VCPUS="${INSTALL_VCPUS:-$DEFAULT_INSTALL_VCPUS}"
    read -rp "  RAM in MB [$DEFAULT_INSTALL_RAM_MB]: " INSTALL_RAM_MB
    INSTALL_RAM_MB="${INSTALL_RAM_MB:-$DEFAULT_INSTALL_RAM_MB}"

    echo "Final (day-to-day) resources, applied after install finishes:"
    read -rp "  vCPUs [$DEFAULT_FINAL_VCPUS]: " FINAL_VCPUS
    FINAL_VCPUS="${FINAL_VCPUS:-$DEFAULT_FINAL_VCPUS}"
    read -rp "  RAM in MB [$DEFAULT_FINAL_RAM_MB]: " FINAL_RAM_MB
    FINAL_RAM_MB="${FINAL_RAM_MB:-$DEFAULT_FINAL_RAM_MB}"

    read -rp "Disk size in GB [$DEFAULT_DISK_GB]: " DISK_GB
    DISK_GB="${DISK_GB:-$DEFAULT_DISK_GB}"
}

# ---------------------------------------------------------------------------
# Step 4: optional post-install scripts (toggles)
# ---------------------------------------------------------------------------

declare -A OPT_LABEL=(
    [skip_grub]="Skip GRUB boot menu after install (hidden, instant boot)"
    [root_ssh]="Enable root SSH login using your SSH key"
    [allow_pw_ssh]="Allow SSH password login (not just key-based)"
    [extra_packages]="Install extra packages (git, htop, curl, net-tools)"
    [auto_login]="Log in automatically to the desktop (no login prompt) - skipped on headless installs"
)
declare -A OPT_STATE=(
    [skip_grub]=1
    [root_ssh]=1
    [allow_pw_ssh]=1
    [extra_packages]=0
    [auto_login]=0
)
OPT_ORDER=(skip_grub root_ssh allow_pw_ssh extra_packages auto_login)

toggles_menu() {
    say "Optional post-install scripts (toggle, then press Enter to continue)"
    while true; do
        local i=1 key
        for key in "${OPT_ORDER[@]}"; do
            local mark=" "
            [ "${OPT_STATE[$key]}" = "1" ] && mark="x"
            printf "  %d) [%s] %s\n" "$i" "$mark" "${OPT_LABEL[$key]}"
            i=$((i + 1))
        done
        read -rp "Toggle number, or Enter to continue: " pick
        [ -z "$pick" ] && break
        if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#OPT_ORDER[@]}" ]; then
            local chosen_key="${OPT_ORDER[$((pick - 1))]}"
            OPT_STATE[$chosen_key]=$((1 - OPT_STATE[$chosen_key]))
        else
            warn "Invalid choice."
        fi
    done
}

# ---------------------------------------------------------------------------
# Step 5: build the autoinstall ISO
# ---------------------------------------------------------------------------

render_cloudinit_template() {
    # render_cloudinit_template <template_file> <out_file>
    # allow-pw is intentionally always true here: actual SSH password-login
    # policy is enforced post-install, uniformly across machine types, in
    # apply_post_install_options (see the allow_pw_ssh toggle).
    local tmpl="$1" out="$2"
    sed \
        -e "s|__REALNAME__|${REALNAME_IN//|/\\|}|g" \
        -e "s|__USERNAME__|${USERNAME_IN//|/\\|}|g" \
        -e "s|__HOSTNAME__|${HOSTNAME_IN//|/\\|}|g" \
        -e "s|__PASSWORD_HASH__|${PASSWORD_HASH//|/\\|}|g" \
        -e "s|__SSH_PUBKEY__|${SSH_PUBKEY//|/\\|}|g" \
        "$tmpl" > "$out"

    if [ "${OPT_STATE[extra_packages]}" != "1" ]; then
        sed -i '/#--EXTRA_PACKAGES_START--/,/#--EXTRA_PACKAGES_END--/d' "$out"
    else
        sed -i '/#--EXTRA_PACKAGES_START--\|#--EXTRA_PACKAGES_END--/d' "$out"
    fi
}

render_preseed_template() {
    # render_preseed_template <template_file> <out_file>
    local tmpl="$1" out="$2"
    local extra_pkgs=""
    [ "${OPT_STATE[extra_packages]}" = "1" ] && extra_pkgs=" git htop curl net-tools"
    sed \
        -e "s|__REALNAME__|${REALNAME_IN//|/\\|}|g" \
        -e "s|__USERNAME__|${USERNAME_IN//|/\\|}|g" \
        -e "s|__HOSTNAME__|${HOSTNAME_IN//|/\\|}|g" \
        -e "s|__PASSWORD_HASH__|${PASSWORD_HASH//|/\\|}|g" \
        -e "s|__EXTRA_PACKAGES__|${extra_pkgs}|g" \
        "$tmpl" > "$out"
}

extract_efi_image() {
    # Finds the hidden El Torito UEFI boot image inside the source ISO and
    # dd's it out to a real file, so it can be re-referenced when rebuilding.
    local iso="$1" out="$2"
    local report line ldsiz lba
    report="$(xorriso -indev "$iso" -report_el_torito plain 2>&1)"
    line="$(echo "$report" | grep -E 'El Torito boot img :.*UEFI')"
    [ -n "$line" ] || die "Could not find a UEFI El Torito boot image in $iso"
    ldsiz="$(echo "$line" | awk '{print $(NF-1)}')"
    lba="$(echo "$line" | awk '{print $NF}')"
    [[ "$ldsiz" =~ ^[0-9]+$ ]] && [[ "$lba" =~ ^[0-9]+$ ]] || die "Failed to parse El Torito report"

    dd if="$iso" of="$out" bs=512 skip=$((lba * 4)) count="$ldsiz" status=none
    file "$out" | grep -qi fat || warn "Extracted EFI image does not look like a FAT filesystem - boot may fail"
}

build_autoinstall_iso() {
    say "Building autoinstall ISO"
    WORK_DIR="$WORK_ROOT/$VM_NAME"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR/extract"

    say "Extracting source ISO"
    xorriso -osirrox on -indev "$SRC_ISO" -extract / "$WORK_DIR/extract" >/dev/null
    chmod -R u+w "$WORK_DIR/extract"

    say "Patching GRUB to add an autoinstall entry"
    local grub_cfg="$WORK_DIR/extract/boot/grub/grub.cfg"
    [ -f "$grub_cfg" ] || die "grub.cfg not found at expected path: $grub_cfg"
    grep -qF "$GRUB_ANCHOR_LINE" "$grub_cfg" || die "GRUB anchor line not found in grub.cfg - machine.conf may be out of date for this ISO"

    # GRUB needs a literal backslash before ';' in the kernel cmdline (it's
    # a command separator in grub.cfg otherwise). Both awk's and GNU sed's
    # string-literal/replacement escape handling of "\;" is unreliable (one
    # strips the backslash on an awk -v value, the other eats it specifically
    # in replacement text), so the backslash is built at runtime via
    # sprintf("%c",92) instead of ever being written as a "\;" token.
    awk -v anchor="$GRUB_ANCHOR_LINE" \
        -v title="$AUTOINSTALL_ENTRY_TITLE" \
        -v args="$AUTOINSTALL_KERNEL_ARGS" \
        -v linux_path="$INSTALL_LINUX_PATH" \
        -v initrd_path="$INSTALL_INITRD_PATH" '
        BEGIN { bs = sprintf("%c", 92); gsub(/;/, bs ";", args) }
        $0 == anchor {
            print "menuentry \"" title "\" {"
            print "    set gfxpayload=keep"
            print "    linux  " linux_path "  " args " ---"
            print "    initrd " initrd_path
            print "}"
            print ""
        }
        { print }
    ' "$grub_cfg" > "$grub_cfg.new"
    mv "$grub_cfg.new" "$grub_cfg"
    # Force a short timeout regardless of what the source ISO's grub.cfg
    # does: some (Ubuntu) set "set timeout=N" directly, so sed can replace
    # it; others (Kali) set no timeout at all anywhere in grub.cfg, which
    # means GRUB defaults to waiting forever (timeout=-1) for a keypress.
    # Prepending our own setting at the very top of the file covers both
    # cases, since a later "set timeout=..." elsewhere would just override
    # it again - which is why this also strips any such later line first.
    sed -i '/^set timeout=/d; /^set timeout_style=/d' "$grub_cfg"
    sed -i '1i set timeout_style=menu\nset timeout=5' "$grub_cfg"

    say "Hashing password"
    PASSWORD_HASH="$(mkpasswd -m sha-512 "$PASSWORD_IN")"

    say "Writing unattended-install config ($INSTALL_METHOD)"
    case "$INSTALL_METHOD" in
        cloud-init)
            mkdir -p "$WORK_DIR/extract/nocloud"
            render_cloudinit_template "${MACHINE_DIR}${USER_DATA_TEMPLATE}" "$WORK_DIR/extract/nocloud/user-data"
            sed -e "s|__HOSTNAME__|$HOSTNAME_IN|g" \
                "${MACHINE_DIR}${META_DATA_TEMPLATE}" > "$WORK_DIR/extract/nocloud/meta-data"
            ;;
        debian-preseed)
            mkdir -p "$WORK_DIR/extract/simple-cdd"
            render_preseed_template "${MACHINE_DIR}${PRESEED_TEMPLATE}" "$WORK_DIR/extract/simple-cdd/custom.preseed"
            ;;
        *)
            die "Unknown INSTALL_METHOD '$INSTALL_METHOD' in ${MACHINE_DIR}machine.conf"
            ;;
    esac

    local efi_img_rel
    if [ "${EFI_IMAGE_HIDDEN:-true}" = "true" ]; then
        say "Extracting hidden EFI boot image from source ISO"
        efi_img_rel="boot/grub/efi.img"
        extract_efi_image "$SRC_ISO" "$WORK_DIR/extract/$efi_img_rel"
    else
        efi_img_rel="$EFI_IMAGE_PATH"
        [ -f "$WORK_DIR/extract/$efi_img_rel" ] || die "Expected EFI image at $efi_img_rel but it wasn't in the extracted ISO - check machine.conf's EFI_IMAGE_PATH"
        say "Using existing EFI boot image at $efi_img_rel"
    fi

    say "Repacking ISO ($ISO_BOOT_STYLE boot style)"
    OUT_ISO="$WORK_DIR/${VM_NAME}-autoinstall.iso"
    case "$ISO_BOOT_STYLE" in
        grub2)
            # BIOS+UEFI hybrid built by grub-mkrescue (Ubuntu/Debian live
            # installers): grub2 owns both the BIOS boot image and the MBR,
            # and the EFI image is referenced as an appended GPT partition.
            xorriso -as mkisofs \
                -r -V "${VM_NAME}-autoinstall" \
                -o "$OUT_ISO" \
                -J -joliet-long \
                -iso-level 3 \
                --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
                -partition_offset 16 \
                --mbr-force-bootable \
                -append_partition 2 0xef "$WORK_DIR/extract/$efi_img_rel" \
                -appended_part_as_gpt \
                -c "$BOOT_CATALOG_PATH" \
                -b "$BIOS_BOOT_IMAGE_PATH" -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info \
                -eltorito-alt-boot \
                -e '--interval:appended_partition_2:::' -no-emul-boot \
                "$WORK_DIR/extract" >/dev/null
            ;;
        isolinux)
            # BIOS+UEFI hybrid built the classic Debian-installer way:
            # isolinux owns BIOS boot, grub's efi.img is a plain file
            # referenced directly (not an appended partition), and the
            # hybrid MBR boot code is reused from the source ISO itself
            # (it's already a working isohybrid image) rather than
            # requiring the separate isolinux/syslinux package for
            # isohdpfx.bin.
            local mbr_template="$WORK_DIR/isohybrid-mbr.bin"
            dd if="$SRC_ISO" of="$mbr_template" bs=1 count=432 status=none
            xorriso -as mkisofs \
                -r -V "${VM_NAME}-autoinstall" \
                -o "$OUT_ISO" \
                -J -joliet-long \
                -iso-level 3 \
                -isohybrid-mbr "$mbr_template" \
                -c "$BOOT_CATALOG_PATH" \
                -b "$BIOS_BOOT_IMAGE_PATH" -no-emul-boot -boot-load-size 4 -boot-info-table \
                -eltorito-alt-boot \
                -e "$efi_img_rel" -no-emul-boot -isohybrid-gpt-basdat \
                "$WORK_DIR/extract" >/dev/null
            ;;
        *)
            die "Unknown ISO_BOOT_STYLE '$ISO_BOOT_STYLE' in ${MACHINE_DIR}machine.conf"
            ;;
    esac

    say "Built: $OUT_ISO"
}

# ---------------------------------------------------------------------------
# Step 6: create the VMware VM (install-time specs, no power-on here)
# ---------------------------------------------------------------------------

find_free_vnc_port() {
    # VNC is only used briefly, at boot, to confirm the autoinstall GRUB
    # entry over the RFB protocol (see run_install_and_finalize /
    # lib/vnc_send_key.py) - bound to 127.0.0.1 only, since there's no
    # password. A fresh port per VM avoids clashing with any other VM that
    # might still have VNC enabled from a previous run.
    python3 -c '
import socket
for p in range(5950, 6050):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", p))
        s.close()
        print(p)
        break
    except OSError:
        continue
'
}

create_vmx() {
    say "Creating VM definition"
    VM_DIR="$VM_BASE_DIR/$VM_NAME"
    mkdir -p "$VM_DIR"
    VMDK="$VM_DIR/$VM_NAME.vmdk"
    VMX="$VM_DIR/$VM_NAME.vmx"

    [ -e "$VMX" ] && die "A VM already exists at $VMX - pick a different name."

    VNC_PORT="$(find_free_vnc_port)"
    [ -n "$VNC_PORT" ] || die "Could not find a free local port for VNC"

    vmware-vdiskmanager -c -s "${DISK_GB}GB" -a lsilogic -t 0 "$VMDK" >/dev/null

    cat > "$VMX" <<EOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "19"
displayName = "$VM_NAME"
guestOS = "$GUEST_OS"
numvcpus = "$INSTALL_VCPUS"
memsize = "$INSTALL_RAM_MB"
mem.hotadd = "FALSE"
cpuid.coresPerSocket = "1"
scsi0.present = "TRUE"
scsi0.virtualDev = "lsilogic"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "$VM_NAME.vmdk"
scsi0:0.deviceType = "disk"
sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "$OUT_ISO"
sata0:0.startConnected = "TRUE"
ethernet0.present = "TRUE"
ethernet0.connectionType = "nat"
ethernet0.virtualDev = "e1000e"
ethernet0.wakeOnPcktRcv = "FALSE"
ethernet0.addressType = "generated"
usb.present = "TRUE"
ehci.present = "TRUE"
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"
vmci0.present = "TRUE"
hpet0.present = "TRUE"
floppy0.present = "FALSE"
firmware = "$FIRMWARE"
tools.syncTime = "TRUE"
tools.upgrade.policy = "upgradeAtPowerCycle"
bios.bootOrder = "cdrom,hdd"
RemoteDisplay.vnc.enabled = "TRUE"
RemoteDisplay.vnc.ip = "127.0.0.1"
RemoteDisplay.vnc.port = "$VNC_PORT"
EOF

    say "VM definition ready at $VMX"
}

# ---------------------------------------------------------------------------
# Step 7: boot, wait for autoinstall to finish, apply toggles, finalize
# ---------------------------------------------------------------------------

get_guest_mac() {
    grep '^ethernet0.generatedAddress' "$VMX" | sed -E 's/.*"([0-9a-fA-F:]+)".*/\1/'
}

wait_for_dhcp_ip() {
    local mac="$1" leases_file="/etc/vmware/vmnet8/dhcpd/dhcpd.leases"
    local ip=""
    local tries=0
    while [ -z "$ip" ] && [ "$tries" -lt 90 ]; do
        ip="$(grep -B2 -i "$mac" "$leases_file" 2>/dev/null | grep -oP 'lease \K[0-9.]+' | tail -1)"
        [ -n "$ip" ] && break
        sleep 10
        tries=$((tries + 1))
    done
    echo "$ip"
}

wait_for_ssh() {
    local ip="$1" user="$2"
    # Default 30 min; machine.conf can raise this for heavier installs (e.g.
    # a full desktop + full-upgrade, which can easily take 20-40+ min just
    # for package retrieval) via SSH_WAIT_MINUTES.
    local max_tries=$(( ${SSH_WAIT_MINUTES:-30} * 6 ))
    local tries=0
    while [ "$tries" -lt "$max_tries" ]; do
        if timeout 6 ssh -i "${SSH_KEY_FILE%.pub}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 "$user@$ip" 'echo ok' 2>/dev/null | grep -q ok; then
            return 0
        fi
        sleep 10
        tries=$((tries + 1))
    done
    return 1
}

apply_post_install_options() {
    local ip="$1"
    local sshkey="${SSH_KEY_FILE%.pub}"
    local ssh_cmd=(ssh -i "$sshkey" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$USERNAME_IN@$ip")

    if [ "${OPT_STATE[skip_grub]}" = "1" ]; then
        say "Applying: skip GRUB boot menu"
        "${ssh_cmd[@]}" "echo '$PASSWORD_IN' | sudo -S bash -c '
            sed -i \"s/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/\" /etc/default/grub
            grep -q GRUB_TIMEOUT_STYLE /etc/default/grub || echo GRUB_TIMEOUT_STYLE=hidden >> /etc/default/grub
            sed -i \"s/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/\" /etc/default/grub
            update-grub
        '"
    fi

    if [ "${OPT_STATE[root_ssh]}" = "1" ]; then
        say "Applying: root SSH login with your key"
        "${ssh_cmd[@]}" "echo '$PASSWORD_IN' | sudo -S bash -c '
            mkdir -p /root/.ssh && chmod 700 /root/.ssh
            echo \"$SSH_PUBKEY\" >> /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
            sed -i \"s/^#\\?PermitRootLogin.*/PermitRootLogin yes/\" /etc/ssh/sshd_config
            grep -q \"^PermitRootLogin\" /etc/ssh/sshd_config || echo \"PermitRootLogin yes\" >> /etc/ssh/sshd_config
            systemctl restart ssh
        '"
    fi

    say "Applying: SSH password login = ${OPT_STATE[allow_pw_ssh]}"
    local pw_value
    pw_value=$([ "${OPT_STATE[allow_pw_ssh]}" = "1" ] && echo yes || echo no)
    "${ssh_cmd[@]}" "echo '$PASSWORD_IN' | sudo -S bash -c '
        sed -i \"s/^#\\?PasswordAuthentication.*/PasswordAuthentication $pw_value/\" /etc/ssh/sshd_config
        grep -q \"^PasswordAuthentication\" /etc/ssh/sshd_config || echo \"PasswordAuthentication $pw_value\" >> /etc/ssh/sshd_config
        systemctl restart ssh
    '"

    if [ "${OPT_STATE[auto_login]}" = "1" ]; then
        say "Applying: desktop auto-login"
        # Only meaningful on a desktop install (LightDM is Kali's XFCE
        # default); headless types like Ubuntu Server have no display
        # manager at all, so this no-ops there instead of failing the run.
        "${ssh_cmd[@]}" "echo '$PASSWORD_IN' | sudo -S bash -c '
            if dpkg -s lightdm >/dev/null 2>&1; then
                mkdir -p /etc/lightdm/lightdm.conf.d
                printf \"[Seat:*]\nautologin-user=%s\nautologin-user-timeout=0\n\" \"$USERNAME_IN\" > /etc/lightdm/lightdm.conf.d/50-autologin.conf
                echo \"INFO: lightdm autologin configured for $USERNAME_IN\"
            else
                echo \"INFO: no lightdm installed (headless system) - skipping auto-login\"
            fi
        '"
    fi
}

finalize_vm() {
    say "Detaching install ISO and shrinking to final resources"
    vmrun stop "$VMX" soft >/dev/null 2>&1 || vmrun stop "$VMX" hard >/dev/null 2>&1 || true
    sleep 5
    # Make sure no stray vmx process is still holding the old config in memory.
    pkill -f "vmware-vmx.*$VM_NAME" 2>/dev/null || true
    sleep 2

    sed -i \
        -e '/^sata0:0.present/d' \
        -e '/^sata0:0.deviceType/d' \
        -e '/^sata0:0.fileName/d' \
        -e '/^sata0:0.startConnected/d' \
        "$VMX"
    sed -i '/^sata0.present/a sata0:0.present = "FALSE"' "$VMX"
    sed -i 's/^bios.bootOrder.*/bios.bootOrder = "hdd"/' "$VMX"
    sed -i "s/^numvcpus.*/numvcpus = \"$FINAL_VCPUS\"/" "$VMX"
    sed -i "s/^memsize.*/memsize = \"$FINAL_RAM_MB\"/" "$VMX"
    sed -i 's/^RemoteDisplay.vnc.enabled.*/RemoteDisplay.vnc.enabled = "FALSE"/' "$VMX"

    say "Done. VM: $VMX"
    echo "  Start it with: vmrun start \"$VMX\" gui"
    echo "  SSH (user):    ssh -i ${SSH_KEY_FILE%.pub} $USERNAME_IN@<ip>"
    [ "${OPT_STATE[root_ssh]}" = "1" ] && echo "  SSH (root):    ssh -i ${SSH_KEY_FILE%.pub} root@<ip>"
}

confirm_boot_menu() {
    # Presses Enter on the console over VNC so the already-highlighted
    # autoinstall GRUB entry gets confirmed, instead of relying on GRUB's
    # own timeout. Some ISOs (Kali) set no timeout anywhere in grub.cfg and
    # wait forever for a keypress, so the inserted "set timeout=5" (see
    # build_autoinstall_iso) is a fallback, not the primary mechanism - this
    # is the same approach HashiCorp Packer's vmware-iso builder uses.
    say "Confirming boot menu over VNC (127.0.0.1:$VNC_PORT)"
    sleep "${BOOT_WAIT_SECONDS:-8}"
    if ! python3 "$SCRIPT_DIR/lib/vnc_send_key.py" 127.0.0.1 "$VNC_PORT" ff0d 2>/tmp/vnc_send_key.err; then
        warn "Could not confirm the boot menu over VNC ($(cat /tmp/vnc_send_key.err 2>/dev/null)) - falling back to GRUB's own timeout"
    fi
}

run_install_and_finalize() {
    say "Powering on for unattended install"
    vmrun start "$VMX" gui >/dev/null

    confirm_boot_menu

    local mac ip
    mac="$(get_guest_mac)"
    say "Waiting for DHCP lease (mac $mac) - this can take a while during install"
    ip="$(wait_for_dhcp_ip "$mac")"
    [ -n "$ip" ] || die "Timed out waiting for the VM to get an IP. Check the VMware console for install errors."
    say "Got IP: $ip - waiting for SSH"

    wait_for_ssh "$ip" "$USERNAME_IN" || die "Install may still be running or failed - SSH never came up. Check the VMware console."
    say "SSH is up - install finished"

    apply_post_install_options "$ip"
    finalize_vm
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
    for bin in xorriso vmware-vdiskmanager vmrun mkpasswd awk sed dd file ssh python3; do
        require_bin "$bin"
    done

    choose_machine_type
    wait_for_iso
    ask_resources
    toggles_menu

    echo
    say "Summary"
    echo "  Machine type : $MACHINE_NAME"
    echo "  VM name      : $VM_NAME"
    echo "  Hostname     : $HOSTNAME_IN"
    echo "  User         : $USERNAME_IN ($REALNAME_IN)"
    echo "  Disk         : ${DISK_GB}GB"
    echo "  Install specs: ${INSTALL_VCPUS} vCPU / ${INSTALL_RAM_MB}MB"
    echo "  Final specs  : ${FINAL_VCPUS} vCPU / ${FINAL_RAM_MB}MB"
    local key
    for key in "${OPT_ORDER[@]}"; do
        local mark="off"
        [ "${OPT_STATE[$key]}" = "1" ] && mark="on"
        echo "  ${OPT_LABEL[$key]}: $mark"
    done
    echo
    read -rp "Press Enter to start building, or Ctrl+C to abort: " _

    build_autoinstall_iso
    create_vmx
    run_install_and_finalize
}

main "$@"
