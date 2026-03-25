import Foundation

/// Disk image operations: clone golden rootfs, expand if needed.
enum DiskManager {

    /// Clone the golden rootfs to the machine's root.img using APFS clonefile.
    /// - Parameters:
    ///   - goldenPath: path to the golden rootfs image
    ///   - destPath: destination path for the cloned image
    ///   - expandTo: if non-nil and larger than golden image, truncate to this size
    static func cloneRootfs(
        goldenPath: String,
        destPath: String,
        expandTo: Int? = nil
    ) throws {
        let fm = FileManager.default

        guard fm.fileExists(atPath: goldenPath) else {
            throw VmmApiError(
                code: "golden_image_not_found",
                message: "Golden rootfs image not found at \(goldenPath)",
                status: .internalServerError)
        }

        // APFS clone: instant copy-on-write
        let srcURL = URL(fileURLWithPath: goldenPath)
        let dstURL = URL(fileURLWithPath: destPath)

        // Remove existing if present
        if fm.fileExists(atPath: destPath) {
            try fm.removeItem(at: dstURL)
        }

        // Use copyItem which leverages APFS clonefile on supported filesystems
        try fm.copyItem(at: srcURL, to: dstURL)

        // Expand if requested
        if let targetSize = expandTo {
            let attrs = try fm.attributesOfItem(atPath: destPath)
            let currentSize = attrs[.size] as? Int ?? 0
            if targetSize > currentSize {
                // truncate expands the file (sparse on APFS)
                let fd = open(destPath, O_WRONLY)
                guard fd >= 0 else {
                    throw VmmApiError(
                        code: "disk_expand_failed",
                        message: "Failed to open \(destPath) for expansion",
                        status: .internalServerError)
                }
                defer { close(fd) }
                let result = ftruncate(fd, off_t(targetSize))
                guard result == 0 else {
                    throw VmmApiError(
                        code: "disk_expand_failed",
                        message: "ftruncate failed: \(String(cString: strerror(errno)))",
                        status: .internalServerError)
                }
            }
        }
    }

    /// Resolve the golden image path. Looks alongside the daemon binary.
    static func goldenRootfsPath() -> String {
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path
            ?? ProcessInfo.processInfo.arguments[0]
                .split(separator: "/").dropLast().joined(separator: "/")
        return "\(execDir)/bentos-arm64-rootfs.img"
    }
}
