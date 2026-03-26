# Next Actions

## Completed
All 24/24 subtasks + E2E validation. First VM boot confirmed S309.

## Follow-ups (distro)
- Kernel should have `virtio_blk`, `ext4`, `crc32c`, `libcrc32c` as built-in (`=y`)
  OR distro build should generate an initramfs with these modules.
- `virtio_net` module should also be built-in or in initramfs for networking.
- Golden rootfs filename mismatch: DiskManager expects `bentos-arm64-rootfs.img`,
  distro produces `bentos-rootfs-arm64.img`. Currently symlinked. Align naming.

## Follow-ups (daemon)
- Console test revealed NIO pipeline ordering matters for WebSocket.
  Tests should cover real WebSocket data flow (not just upgrade).
- Network failure at boot (`eth0` not found) — virtio_net module needed.

## Standing By
Awaiting next direction from Alfred/Cafe.
