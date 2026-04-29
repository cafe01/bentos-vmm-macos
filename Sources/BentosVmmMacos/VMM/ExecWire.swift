import Foundation
import Darwin

// MARK: - ExecWire
//
// TLV framing codec for the bentos-execd vsock wire protocol.
// Frame format: [type: UInt8][length: UInt32 LE][payload: Data]
// Max payload: 1 MiB.
//
// Host → Guest type bytes (0x01-0x0F):
//   0x01  EXEC_REQUEST   protobuf Bentos_Exec_ExecRequest
//   0x02  STDIN_DATA     raw bytes
//   0x03  STDIN_EOF      empty payload
//   0x04  WINDOW_RESIZE  protobuf Bentos_Exec_WindowResize
//   0x05  SIGNAL         protobuf Bentos_Exec_Signal
//
// Guest → Host type bytes (0x10-0x1F):
//   0x10  EXEC_STARTED   protobuf Bentos_Exec_ExecStarted
//   0x11  STDOUT_DATA    raw bytes
//   0x12  STDERR_DATA    raw bytes
//   0x13  EXIT_STATUS    protobuf Bentos_Exec_ExitStatus
//   0x14  EXEC_ERROR     protobuf Bentos_Exec_ExecError

enum ExecWire {
    // MARK: Type constants
    static let typeExecRequest:  UInt8 = 0x01
    static let typeStdinData:    UInt8 = 0x02
    static let typeStdinEof:     UInt8 = 0x03
    static let typeWindowResize: UInt8 = 0x04
    static let typeSignal:       UInt8 = 0x05

    static let typeExecStarted:  UInt8 = 0x10
    static let typeStdoutData:   UInt8 = 0x11
    static let typeStderrData:   UInt8 = 0x12
    static let typeExitStatus:   UInt8 = 0x13
    static let typeExecError:    UInt8 = 0x14

    static let maxPayloadBytes: Int = 1_048_576  // 1 MiB

    // MARK: - Encode

    /// Build a TLV frame.
    static func frame(type: UInt8, payload: Data = Data()) -> Data {
        var result = Data(capacity: 5 + payload.count)
        result.append(type)
        var len = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &len) { result.append(contentsOf: $0) }
        result.append(payload)
        return result
    }

    // MARK: - Blocking read (use from background Task only)

    /// Read exactly `count` bytes from `fd`. Loops through short reads and EINTR.
    /// Throws `ExecWireError.eof` on EOF, `ExecWireError.ioError` on other errors.
    static func readExact(fd: Int32, count: Int) throws -> Data {
        var result = Data(capacity: count)
        var remaining = count
        while remaining > 0 {
            var buf = Data(count: remaining)
            let n = buf.withUnsafeMutableBytes { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress!, remaining)
            }
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                throw ExecWireError.ioError(e)
            }
            if n == 0 { throw ExecWireError.eof }
            result.append(buf.prefix(n))
            remaining -= n
        }
        return result
    }

    /// Blocking read of one TLV frame from `fd`.
    /// Call only from a background Task or thread — this blocks.
    static func readFrame(fd: Int32) throws -> (type: UInt8, payload: Data) {
        let header = try readExact(fd: fd, count: 5)
        let type = header[0]
        let length = UInt32(littleEndian: header.withUnsafeBytes {
            $0.load(fromByteOffset: 1, as: UInt32.self)
        })
        guard Int(length) <= maxPayloadBytes else {
            throw ExecWireError.frameTooLarge(length)
        }
        let payload = length > 0 ? try readExact(fd: fd, count: Int(length)) : Data()
        return (type, payload)
    }

    // MARK: - Blocking write

    /// Write `data` to `fd`. Loops through short writes and EINTR.
    static func writeAll(fd: Int32, data: Data) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let slice = data[offset...]
            let n = slice.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress!, ptr.count)
            }
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                throw ExecWireError.ioError(e)
            }
            if n == 0 { throw ExecWireError.eof }
            offset = data.index(offset, offsetBy: n)
        }
    }

    // MARK: - Async stream of frames

    /// Returns an AsyncStream that reads TLV frames from `fd` on a background Task.
    /// When the stream terminates or is cancelled, the background Task is cancelled
    /// (the next `read()` will unblock when `fd` is closed by the caller).
    static func frameStream(fd: Int32) -> AsyncStream<Result<(UInt8, Data), Error>> {
        let (stream, continuation) = AsyncStream<Result<(UInt8, Data), Error>>.makeStream()
        let task = Task.detached(priority: .utility) {
            do {
                while !Task.isCancelled {
                    let frame = try ExecWire.readFrame(fd: fd)
                    continuation.yield(.success(frame))
                }
            } catch {
                continuation.yield(.failure(error))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

// MARK: - FileHandle async read stream

extension FileHandle {
    /// AsyncStream<Data> driven by `readabilityHandler` (GCD). Non-blocking.
    /// The stream terminates when EOF is detected (empty data from handler).
    var asyncReadStream: AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let handle = self
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(chunk)
            }
        }
        continuation.onTermination = { _ in
            handle.readabilityHandler = nil
        }
        return stream
    }
}

// MARK: - Errors

enum ExecWireError: Error {
    case eof
    case ioError(Int32)
    case frameTooLarge(UInt32)
}
