@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Adversarial coverage for the total-document-byte-count guard (MEDIUM #7): unlike nesting
/// depth (bounded to protect the call stack), nothing else in `LosslessJSONParser` bounds
/// the flat cost of scanning a huge document with no nesting at all -- a pathologically
/// large document could otherwise force multiple full-size O(n) copies purely from its own
/// size. Every boundary test below uses a small caller-supplied `maxByteCount` override
/// (never `LosslessJSONParser.defaultMaxDocumentByteCount` itself) so exact-boundary
/// coverage never allocates anywhere near 16 MiB in CI.
@Suite("Lossless JSON document size")
struct LosslessJSONDocumentSizeTests {
    /// The real production default is exercised only as a numeric constant, never by
    /// actually allocating a document that size -- proves a future edit can't silently
    /// shrink or grow this ceiling unnoticed without also proving its generous, documented
    /// intent (>1000x the largest real governed fixture; see the property's own doc
    /// comment).
    @Test("The default document size ceiling is exactly 16 MiB")
    func defaultCeilingIsSixteenMebibytes() {
        #expect(LosslessJSONParser.defaultMaxDocumentByteCount == 16 * 1024 * 1024)
    }

    @Test("A document exactly at a custom byte-count limit parses")
    func documentAtCustomLimitParses() throws {
        // `"0"` padded with leading whitespace to hit an exact byte count; whitespace before
        // the root value is ordinary, valid JSON.
        let limit = 32
        let payload = String(repeating: " ", count: limit - 1) + "0"
        let data = Data(payload.utf8)
        #expect(data.count == limit)
        let value = try LosslessJSONParser.parse(data, maxByteCount: limit)
        #expect(value == .number(.integer(0)))
    }

    @Test("A document one byte past a custom byte-count limit is rejected")
    func documentOnePastCustomLimitRejected() {
        let limit = 32
        let payload = String(repeating: " ", count: limit) + "0"
        let data = Data(payload.utf8)
        #expect(data.count == limit + 1)
        let expectedError = LosslessJSONParserError.documentTooLarge(
            byteCount: limit + 1, limit: limit
        )
        #expect(throws: expectedError) {
            try LosslessJSONParser.parse(data, maxByteCount: limit)
        }
    }

    @Test("The size guard reports the exact byte count and limit that were exceeded")
    func sizeGuardReportsExactCounts() {
        let limit = 4
        let data = Data("123456".utf8)
        do {
            _ = try LosslessJSONParser.parse(data, maxByteCount: limit)
            Issue.record("Expected parse to throw")
        } catch let LosslessJSONParserError.documentTooLarge(byteCount, reportedLimit) {
            #expect(byteCount == 6)
            #expect(reportedLimit == limit)
        } catch {
            Issue.record("Expected .documentTooLarge, got \(error)")
        }
    }

    @Test("The size guard runs before any UTF-8 validation or byte scanning")
    func sizeGuardRunsBeforeContentValidation() {
        // Deliberately invalid UTF-8 (0xFF is not a valid lead byte anywhere) *and* over an
        // intentionally tiny limit: if the size guard truly runs first, this throws
        // `.documentTooLarge`, never `.invalidUTF8` -- proving an oversized document's cost
        // is O(1) rather than proportional to however much (invalid) content follows.
        let data = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: LosslessJSONParserError.documentTooLarge(byteCount: 5, limit: 2)) {
            try LosslessJSONParser.parse(data, maxByteCount: 2)
        }
    }

    @Test("ContractJSON.decode threads a custom byte-count limit through to the parser")
    func contractJSONDecodeThreadsCustomLimit() {
        let data = Data("\"this string is long enough to exceed a tiny limit\"".utf8)
        #expect(throws: (any Error).self) {
            try ContractJSON.decode(JSONValue.self, from: data, maxByteCount: 4)
        }
    }

    @Test("ContractJSON.decode accepts a document within a custom byte-count limit")
    func contractJSONDecodeAcceptsWithinCustomLimit() throws {
        let data = Data("\"ok\"".utf8)
        let decoded = try ContractJSON.decode(JSONValue.self, from: data, maxByteCount: data.count)
        #expect(decoded == .string("ok"))
    }

    @Test("ContractJSON.decode accepts ordinary fixtures under the real production default")
    func contractJSONDecodeAcceptsUnderRealDefault() throws {
        // No override at all: proves the default parameter value itself (not just a
        // caller-supplied override) is wired correctly end to end for ordinary, realistic
        // documents.
        let data = Data(#"{"a": 1, "b": [true, false, null]}"#.utf8)
        let decoded = try ContractJSON.decode(JSONValue.self, from: data)
        #expect(
            decoded == .object([
                "a": .number(.integer(1)),
                "b": .array([.bool(true), .bool(false), .null]),
            ])
        )
    }
}
