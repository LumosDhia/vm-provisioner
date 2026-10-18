#!/usr/bin/env python3
"""Send a single keystroke to a VNC server (RFB protocol), no dependencies.

Written for provision.sh to press Enter on a VMware VM's console at boot,
confirming the already-highlighted autoinstall GRUB entry without relying on
GRUB's own timeout (some ISOs, e.g. Kali's, set no timeout at all and wait
forever for a keypress - see README). This is the same approach HashiCorp
Packer's vmware-iso builder uses (VNC + boot_command) to drive an installer
boot menu unattended.

Supports RFB 3.3, 3.7 and 3.8 with security type "None" only (no password) -
the provisioner enables VNC bound to 127.0.0.1 only, for this script's brief
use during boot, which is why no auth is needed.

Usage: vnc_send_key.py HOST PORT KEYSYM [KEYSYM ...]
  KEYSYM is a hex X11 keysym, e.g. ff0d for Return.
"""
import socket
import struct
import sys
import time

NONE_SECURITY = 1


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("VNC server closed the connection unexpectedly")
        buf += chunk
    return buf


def handshake(sock):
    server_version = recv_exact(sock, 12)
    if not server_version.startswith(b"RFB "):
        raise ValueError(f"Not an RFB server: {server_version!r}")
    major, minor = server_version[4:7], server_version[8:11]
    # Reply with the same version the server offered - avoids guessing
    # whether it understands a version we'd otherwise hardcode.
    sock.sendall(server_version)

    if int(major) == 3 and int(minor) < 7:
        # RFB 3.3: server dictates the security type directly, 4 bytes.
        sec_type = struct.unpack(">I", recv_exact(sock, 4))[0]
        if sec_type != NONE_SECURITY:
            raise ValueError(f"Server requires security type {sec_type}, only None (1) is supported")
    else:
        # RFB 3.7+: server offers a list, client picks one.
        count = recv_exact(sock, 1)[0]
        types = recv_exact(sock, count)
        if NONE_SECURITY not in types:
            raise ValueError(f"Server does not offer security type None, offers: {list(types)}")
        sock.sendall(bytes([NONE_SECURITY]))
        if int(major) == 3 and int(minor) >= 8:
            result = struct.unpack(">I", recv_exact(sock, 4))[0]
            if result != 0:
                raise ValueError("VNC security handshake failed")

    # ClientInit: shared-flag = 1 (share the desktop with other clients)
    sock.sendall(b"\x01")

    # ServerInit: width(2) height(2) pixel-format(16) name-length(4) name(...)
    header = recv_exact(sock, 2 + 2 + 16 + 4)
    name_len = struct.unpack(">I", header[20:24])[0]
    recv_exact(sock, name_len)  # desktop name, unused


def send_key(sock, keysym, down):
    # KeyEvent: message-type(1)=4, down-flag(1), padding(2), keysym(4)
    sock.sendall(struct.pack(">BBHI", 4, 1 if down else 0, 0, keysym))


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(1)
    host, port = sys.argv[1], int(sys.argv[2])
    keysyms = [int(k, 16) for k in sys.argv[3:]]

    with socket.create_connection((host, port), timeout=10) as sock:
        handshake(sock)
        for keysym in keysyms:
            send_key(sock, keysym, down=True)
            time.sleep(0.05)
            send_key(sock, keysym, down=False)
            time.sleep(0.1)


if __name__ == "__main__":
    main()
