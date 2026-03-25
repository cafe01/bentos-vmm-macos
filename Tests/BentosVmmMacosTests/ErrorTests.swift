import Foundation
import Testing
@testable import BentosVmmMacos

@Suite("Error envelope")
struct ErrorTests {

    @Test func notFoundEnvelope() throws {
        let err = VmmApiError.notFound("No route for GET /nope")
        let json = try JSONSerialization.jsonObject(
            with: Data(err.jsonBytes)) as! [String: Any]
        #expect(json["code"] as? String == "not_found")
        #expect(json["message"] as? String == "No route for GET /nope")
        #expect(err.status == .notFound)
    }

    @Test func machineNotFoundEnvelope() throws {
        let err = VmmApiError.machineNotFound("abc")
        let json = try JSONSerialization.jsonObject(
            with: Data(err.jsonBytes)) as! [String: Any]
        #expect(json["code"] as? String == "machine_not_found")
        #expect(json["message"] as? String == "No machine with id 'abc'")
        #expect(err.status == .notFound)
    }

    @Test func badRequestEnvelope() throws {
        let err = VmmApiError.badRequest("Invalid JSON")
        #expect(err.status == .badRequest)
        let json = try JSONSerialization.jsonObject(
            with: Data(err.jsonBytes)) as! [String: Any]
        #expect(json["code"] as? String == "bad_request")
    }

    @Test func notImplementedEnvelope() throws {
        let err = VmmApiError.notImplemented("POST /api/v1/machines/{id}/start")
        #expect(err.status == .notImplemented)
        let json = try JSONSerialization.jsonObject(
            with: Data(err.jsonBytes)) as! [String: Any]
        #expect(json["code"] as? String == "not_implemented")
    }

    @Test func methodNotAllowedEnvelope() throws {
        let err = VmmApiError.methodNotAllowed("DELETE", "/api/v1/vmm/ping")
        #expect(err.status == .methodNotAllowed)
    }

    @Test func escapesQuotesInMessage() throws {
        let err = VmmApiError.badRequest("Invalid \"field\"")
        let json = try JSONSerialization.jsonObject(
            with: Data(err.jsonBytes)) as! [String: Any]
        #expect(json["message"] as? String == "Invalid \"field\"")
    }
}
