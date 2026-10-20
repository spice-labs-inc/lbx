#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# vm-net-attach — create a tap device and attach it to the llm-in-a-box
# VM bridge (br-vm0), for booting qemu VMs with bridged networking inside
# a sysbox container.
#
# Usage: vm-net-attach <tap-name>
#
# After running this, boot qemu with:
#   qemu-system-x86_64 ... \
#       -netdev tap,id=net0,ifname=<tap-name>,script=no,downscript=no \
#       -device virtio-net-pci,netdev=net0
#
# The guest should configure a static IP on the 192.168.200.0/24 subnet
# (br-vm0 is 192.168.200.1) — e.g. 192.168.200.2/24, gateway 192.168.200.1.
# ---------------------------------------------------------------------------
set -euo pipefail

TAP="${1:?Usage: vm-net-attach <tap-name>}"

if ! ip link show br-vm0 >/dev/null 2>&1; then
    echo "ERROR: br-vm0 bridge not found. This requires /dev/net/tun + NET_ADMIN" >&2
    echo "       (sysbox runtime auto-grants these.)" >&2
    exit 1
fi

ip tuntap add dev "$TAP" mode tap
ip link set "$TAP" master br-vm0
ip link set "$TAP" up

echo "Attached $TAP to br-vm0 (192.168.200.1/24). Boot qemu with:"
echo "  qemu-system-x86_64 ... -netdev tap,id=net0,ifname=$TAP,script=no,downscript=no -device virtio-net-pci,netdev=net0"
