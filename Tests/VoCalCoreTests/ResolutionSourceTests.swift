import Foundation
import Testing
@testable import VoCalCore

@Suite("ResolutionSource")
struct ResolutionSourceTests {
    // INCIDENT class (2026-09-24): a new source value on the wire ("fatsecret") would have
    // failed every parse decode on the shipped builds. Unknown values decode as a resolved
    // database food; known ones decode as themselves.
    @Test("An unknown source decodes as other, never as a decode failure")
    func unknownSourceDecodes() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ResolutionSource.self, from: Data("\"fatsecret\"".utf8)) == .fatsecret)
        #expect(try decoder.decode(ResolutionSource.self, from: Data("\"some_future_source\"".utf8)) == .other)
        #expect(try decoder.decode(ResolutionSource.self, from: Data("\"manual\"".utf8)) == .manual)
    }
}
