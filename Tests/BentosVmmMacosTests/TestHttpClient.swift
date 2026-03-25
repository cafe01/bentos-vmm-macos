import Foundation

/// Minimal HTTP client over Unix socket for tests. Uses raw Foundation sockets.
struct TestHttpClient {
    let socketPath: String

    struct Response {
        let statusCode: Int
        let body: Data

        var json: [String: Any]? {
            try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
    }

    func request(
        method: String = "GET",
        path: String,
        body: Data? = nil
    ) async throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestClientError.socketCreation }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                for (i, byte) in pathBytes.enumerated() where i < 104 {
                    dest[i] = byte
                }
            }
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw TestClientError.connectionRefused }

        // Build HTTP request.
        var request = "\(method) \(path) HTTP/1.1\r\n"
        request += "Host: localhost\r\n"
        request += "Connection: close\r\n"
        if let body {
            request += "Content-Type: application/json\r\n"
            request += "Content-Length: \(body.count)\r\n"
        }
        request += "\r\n"

        var requestData = Data(request.utf8)
        if let body { requestData.append(body) }

        _ = requestData.withUnsafeBytes { ptr in
            Darwin.send(fd, ptr.baseAddress!, ptr.count, 0)
        }

        // Read response.
        var responseData = Data()
        let bufSize = 8192
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while true {
            let n = Darwin.recv(fd, buf, bufSize, 0)
            if n <= 0 { break }
            responseData.append(buf, count: n)
        }

        return try parseHTTPResponse(responseData)
    }

    private func parseHTTPResponse(_ data: Data) throws -> Response {
        guard let str = String(data: data, encoding: .utf8) else {
            throw TestClientError.invalidResponse
        }
        // Split headers from body.
        let parts = str.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 2 else { throw TestClientError.invalidResponse }

        let headerSection = parts[0]
        let bodyStr = parts.dropFirst().joined(separator: "\r\n\r\n")

        // Parse status line.
        let lines = headerSection.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw TestClientError.invalidResponse }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2,
              let statusCode = Int(statusParts[1]) else {
            throw TestClientError.invalidResponse
        }

        return Response(
            statusCode: statusCode,
            body: Data(bodyStr.utf8)
        )
    }
}

enum TestClientError: Error {
    case socketCreation
    case connectionRefused
    case invalidResponse
}
