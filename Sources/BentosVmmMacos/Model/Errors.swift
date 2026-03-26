import Foundation

/// API error with HTTP status mapping. Thrown from handlers, caught by router.
struct VmmApiError: Error, Sendable {
    let code: String
    let message: String
    let status: HTTPStatus

    /// JSON envelope: `{"code":"...","message":"..."}`.
    var jsonBytes: [UInt8] {
        // Hand-built to avoid JSONEncoder overhead for a trivial shape.
        let json = "{\"code\":\"\(code)\",\"message\":\"\(escaped)\"}"
        return Array(json.utf8)
    }

    private var escaped: String {
        message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - HTTP status (lightweight, no Foundation dependency)

enum HTTPStatus: Int, Sendable {
    case ok = 200
    case noContent = 204
    case badRequest = 400
    case notFound = 404
    case methodNotAllowed = 405
    case conflict = 409
    case internalServerError = 500
    case notImplemented = 501
}

// MARK: - Common errors

extension VmmApiError {
    static func notFound(_ msg: String) -> VmmApiError {
        VmmApiError(code: "not_found", message: msg, status: .notFound)
    }

    static func machineNotFound(_ id: String) -> VmmApiError {
        VmmApiError(code: "machine_not_found", message: "No machine with id '\(id)'", status: .notFound)
    }

    static func badRequest(_ msg: String) -> VmmApiError {
        VmmApiError(code: "bad_request", message: msg, status: .badRequest)
    }

    static func notImplemented(_ endpoint: String) -> VmmApiError {
        VmmApiError(code: "not_implemented", message: "\(endpoint) is not implemented yet", status: .notImplemented)
    }

    static func methodNotAllowed(_ method: String, _ path: String) -> VmmApiError {
        VmmApiError(code: "method_not_allowed", message: "\(method) \(path) is not allowed", status: .methodNotAllowed)
    }

    static func conflict(_ msg: String) -> VmmApiError {
        VmmApiError(code: "conflict", message: msg, status: .conflict)
    }

    static func internalError(_ msg: String) -> VmmApiError {
        VmmApiError(code: "internal_error", message: msg, status: .internalServerError)
    }

    static func snapshotNotFound(_ machineId: String, _ snapshotId: String) -> VmmApiError {
        VmmApiError(
            code: "snapshot_not_found",
            message: "No snapshot '\(snapshotId)' for machine '\(machineId)'",
            status: .notFound)
    }
}
