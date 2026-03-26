# E2E Learnings — First VM Boot (S309)

## VZ Framework: serialPorts vs consoleDevices
- `vzConfig.serialPorts` with `VZVirtioConsoleDeviceSerialPortConfiguration` = Linux `hvc0`
- `vzConfig.consoleDevices` with `VZVirtioConsoleDeviceConfiguration` = multi-port console,
  does NOT produce output on `hvc0`. The kernel sees the device but doesn't route `console=hvc0`
  output through it.
- Source: Apple sample code + xpnsec blog confirm `serialPorts` is the correct property.

## NIO WebSocket Pipeline
- `configureHTTPServerPipeline(withServerUpgrade:)` removes HTTP codec + upgrade handler on
  successful WebSocket upgrade. But custom handlers added via `.flatMap` after pipeline setup
  are NOT removed. They remain and receive raw WebSocket frame bytes.
- Fix: remove custom HTTP handler in `completionHandler` closure.
- The `completionHandler` fires on the channel's event loop — safe for pipeline mutation.
- `syncOperations.removeHandler(context:)` is the non-deprecated API.

## Kernel Module Dependencies for VZ Boot
Minimum modules needed for VZ + ext4 rootfs:
1. `virtio_blk.ko` — block device access
2. `crc32c_generic.ko` — crypto prerequisite for ext4
3. `libcrc32c.ko` — CRC32C library wrapper
4. `crc16.ko` — ext4 metadata checksums
5. `mbcache.ko` — ext4 extended attribute cache
6. `jbd2.ko` — journaling layer
7. `ext4.ko` — filesystem

Load order matters: crc32c before jbd2, jbd2 before ext4, mbcache before ext4.

## Docker as Cross-Compile Escape Hatch
On macOS, `docker run --platform linux/arm64 busybox:musl cat /bin/busybox` extracts a
static ARM64 busybox binary without any cross-compiler toolchain. Good for building
initramfs on macOS.
