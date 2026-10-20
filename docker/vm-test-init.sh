#!/bin/busybox sh
# ---------------------------------------------------------------------------
# vm-test-init.sh — init script for the minimal test-VM initramfs baked into
# the sysbox image (see tests/verify-vm-bridged-network.sh). Not part of
# the user-facing product —
# this only exists to give the runtime test a real, bootable guest that
# serves HTTP over the bridged network, so the "VM can host a web server"
# claim is actually verified against a real boot, not simulated.
#
# Brings up eth0 with a static IP on the llm-in-a-box VM bridge subnet,
# serves a static page over HTTP via busybox httpd, and prints a readiness
# marker the test script waits for on the serial console.
# ---------------------------------------------------------------------------
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys

# virtio_net may be built-in or a module depending on kernel flavor; try to
# load it if present, ignore failure if it's already built in.
/bin/busybox modprobe virtio_net 2>/dev/null

/bin/busybox ip link set lo up
/bin/busybox ip link set eth0 up
/bin/busybox ip addr add 192.168.200.2/24 dev eth0
/bin/busybox ip route add default via 192.168.200.1

/bin/busybox httpd -f -p 80 -h /www &

echo VM-NET-TEST-READY

while true; do
    /bin/busybox sleep 3600
done
