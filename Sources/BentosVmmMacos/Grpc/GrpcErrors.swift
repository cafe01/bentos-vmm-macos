import GRPCCore

// MARK: - VmmApiError → RPCError

extension VmmApiError {
    /// Translate an internal API error to a gRPC RPCError for service handlers.
    var rpcError: RPCError {
        let code: RPCError.Code
        switch status {
        case .notFound:          code = .notFound
        case .conflict:          code = .failedPrecondition
        case .badRequest:        code = .invalidArgument
        case .internalServerError: code = .internalError
        case .notImplemented:    code = .unimplemented
        case .methodNotAllowed:  code = .unimplemented
        default:                 code = .internalError
        }
        return RPCError(code: code, message: message)
    }
}
