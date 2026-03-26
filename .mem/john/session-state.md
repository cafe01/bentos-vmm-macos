# Session State — S309 E2E validated: first VM boot

## What Happened This Head (john-vmm-swift-05, S309)
First VM boot — end-to-end validation of the Swift daemon with real kernel + rootfs.

### Two bugs fixed
1. **ConfigTranslator.swift** — Console used `vzConfig.consoleDevices` with
   `VZVirtioConsoleDeviceConfiguration`. This does NOT map to `hvc0` in Linux.
   Fixed: use `vzConfig.serialPorts` with `VZVirtioConsoleDeviceSerialPortConfiguration`.
   This is the correct VZ API for Linux serial console (`hvc0`).

2. **HttpServer.swift** — After NIO WebSocket upgrade, `HttpHandler` remained in the
   pipeline (NIO only removes the codec + upgrade handler, not custom handlers added
   via `.flatMap`). Raw WebSocket frames hit `HttpHandler` -> fatal error.
   Fixed: remove `HttpHandler` in the upgrade `completionHandler`.

### Initramfs workaround
The distro kernel has critical drivers as modules:
- `CONFIG_VIRTIO_BLK=m` (can't access root disk)
- `CONFIG_EXT4_FS=m` (can't mount root filesystem)
- `CONFIG_CRYPTO_CRC32C=m`, `CONFIG_LIBCRC32C=m` (ext4 dependency)

Built a minimal initramfs (~7MB) with Docker-sourced busybox (ARM64 static) + these
modules. Loads in order: virtio_blk, crc32c_generic, libcrc32c, crc16, mbcache, jbd2, ext4.
Then mounts /dev/vda and switch_root to real init.

### Boot result
Linux 6.12.77 (aarch64) boots to Alpine Linux 3.21 login prompt.
OpenRC starts all services (syslog, sshd). Console works via WebSocket.
Network fails (virtio_net=m not in initramfs) — expected, non-blocking.

## Cumulative State (S307-S309)
- M0-M5: 24/24 subtasks complete. 121 tests.
- E2E: validated. VM boots, reaches login prompt, console bidirectional.
- Two production bugs found and fixed during validation.

## Architecture (unchanged)
- Sources/BentosVmmMacos/ — 16 Swift files across 4 directories
- Tests/BentosVmmMacosTests/ — 15 test files, 121 tests
