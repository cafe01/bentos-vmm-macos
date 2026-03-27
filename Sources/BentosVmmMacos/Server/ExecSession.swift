import Foundation
import Virtualization

/// One-shot exec over vsock. Sends a TLV-framed ExecRequest to bentos-execd,
/// reads TLV-framed response frames until ExitStatus arrives.
///
/// Wire format (matches bentos-execd TLV protocol):
///   Frame: [type: u16 BE][length: u32 BE][payload: N bytes]
///
/// Message types (from exec_wire.proto constants in bentos-execd):
///   1 = ExecRequest
///   2 = ExecResponse (error)
///   3 = StdoutData
///   4 = StderrData
///   5 = ExitStatus
///   6 = WindowResize (not used here)
///   7 = Signal (not used here)
enum ExecSession {

    // MARK: - TLV constants (must match bentos-execd wire.rs)

    private static let msgTypeExecRequest:  UInt16 = 1
    private static let msgTypeExecResponse: UInt16 = 2
    private static let msgTypeStdoutData:   UInt16 = 3
    private static let msgTypeStderrData:   UInt16 = 4
    private static let msgTypeExitStatus:   UInt16 = 5

    // MARK: - One-shot exec

    /// Connect, send ExecRequest, collect stdout/stderr, return on ExitStatus.
    static func runOneShot(
        conn: VZVirtioSocketConnection,
        request: ExecRunRequest
    ) async throws -> ExecRunResponse {
        let fd = conn.fileDescriptor
        defer { conn.close() }

        // Encode ExecRequest as protobuf-like manual encoding.
        // bentos-execd uses prost-generated types from exec_wire.proto.
        // Proto fields: command (repeated string, field 1), env (map, field 2),
        //   working_dir (optional string, field 3), tty (bool, field 4).
        let payload = try encodeExecRequest(request)
        try writeFrame(fd: fd, type: msgTypeExecRequest, payload: payload)

        // Read frames until ExitStatus.
        var stdoutData = Data()
        var stderrData = Data()
        var exitCode = 0

        while true {
            let (msgType, framePayload) = try readFrame(fd: fd)
            switch msgType {
            case msgTypeStdoutData:
                stdoutData.append(contentsOf: framePayload)
            case msgTypeStderrData:
                stderrData.append(contentsOf: framePayload)
            case msgTypeExitStatus:
                exitCode = decodeExitStatus(framePayload)
                // ExitStatus is the terminal frame.
                return ExecRunResponse(
                    exitCode: exitCode,
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "")
            case msgTypeExecResponse:
                // Error frame from bentos-execd (exec failed to spawn).
                let errMsg = String(bytes: framePayload, encoding: .utf8) ?? "exec failed"
                throw VmmApiError(
                    code: "exec_failed",
                    message: errMsg,
                    status: .internalServerError)
            default:
                // Unknown frame type — skip.
                break
            }
        }
    }

    // MARK: - TLV framing

    private static func writeFrame(fd: Int32, type: UInt16, payload: [UInt8]) throws {
        var header = Data(count: 6)
        header[0] = UInt8(type >> 8)
        header[1] = UInt8(type & 0xFF)
        let len = UInt32(payload.count)
        header[2] = UInt8(len >> 24)
        header[3] = UInt8((len >> 16) & 0xFF)
        header[4] = UInt8((len >> 8) & 0xFF)
        header[5] = UInt8(len & 0xFF)

        var buf = header
        buf.append(contentsOf: payload)
        let written = buf.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, ptr.count)
        }
        guard written == buf.count else {
            throw VmmApiError(code: "exec_write_failed",
                             message: "Failed to write TLV frame to vsock",
                             status: .internalServerError)
        }
    }

    private static func readFrame(fd: Int32) throws -> (UInt16, [UInt8]) {
        let header = try readExact(fd: fd, count: 6)
        let msgType = (UInt16(header[0]) << 8) | UInt16(header[1])
        let length = (UInt32(header[2]) << 24) | (UInt32(header[3]) << 16)
                   | (UInt32(header[4]) << 8)  | UInt32(header[5])
        let payload = try readExact(fd: fd, count: Int(length))
        return (msgType, payload)
    }

    private static func readExact(fd: Int32, count: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let n = buf.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress!.advanced(by: received), count - received)
            }
            guard n > 0 else {
                throw VmmApiError(code: "exec_read_failed",
                                 message: "vsock connection closed unexpectedly",
                                 status: .internalServerError)
            }
            received += n
        }
        return buf
    }

    // MARK: - Protobuf encoding

    /// Encode ExecRunRequest as a minimal protobuf binary.
    /// Proto schema (exec_wire.proto, ExecRequest message):
    ///   repeated string command = 1;
    ///   map<string,string> env = 2;
    ///   optional string working_dir = 3;
    ///   bool tty = 4;
    private static func encodeExecRequest(_ req: ExecRunRequest) throws -> [UInt8] {
        var out = [UInt8]()

        // field 1 (repeated string command): tag = (1 << 3) | 2 = 0x0A
        for arg in req.command {
            let bytes = Array(arg.utf8)
            out.append(0x0A)
            out.append(contentsOf: encodeVarint(UInt64(bytes.count)))
            out.append(contentsOf: bytes)
        }

        // field 2 (map<string,string> env): tag = (2 << 3) | 2 = 0x12
        // Each map entry is encoded as a nested message: field 1 (key) + field 2 (value).
        for (k, v) in req.env {
            var entry = [UInt8]()
            let kBytes = Array(k.utf8)
            let vBytes = Array(v.utf8)
            entry.append(0x0A)
            entry.append(contentsOf: encodeVarint(UInt64(kBytes.count)))
            entry.append(contentsOf: kBytes)
            entry.append(0x12)
            entry.append(contentsOf: encodeVarint(UInt64(vBytes.count)))
            entry.append(contentsOf: vBytes)
            out.append(0x12)
            out.append(contentsOf: encodeVarint(UInt64(entry.count)))
            out.append(contentsOf: entry)
        }

        // field 3 (optional string working_dir): tag = (3 << 3) | 2 = 0x1A
        if let wd = req.workingDir {
            let bytes = Array(wd.utf8)
            out.append(0x1A)
            out.append(contentsOf: encodeVarint(UInt64(bytes.count)))
            out.append(contentsOf: bytes)
        }

        // field 4 (bool tty): tag = (4 << 3) | 0 = 0x20
        if req.tty {
            out.append(0x20)
            out.append(0x01)
        }

        return out
    }

    /// Decode ExitStatus protobuf. Schema: int32 exit_code = 1;
    private static func decodeExitStatus(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 2, bytes[0] == 0x08 else { return 0 }
        // field 1 (int32 exit_code): tag = (1 << 3) | 0 = 0x08, then varint
        var value: UInt64 = 0
        var shift = 0
        for b in bytes.dropFirst() {
            value |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
        }
        return Int(Int32(bitPattern: UInt32(value & 0xFFFFFFFF)))
    }

    private static func encodeVarint(_ value: UInt64) -> [UInt8] {
        var v = value
        var out = [UInt8]()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }
}
