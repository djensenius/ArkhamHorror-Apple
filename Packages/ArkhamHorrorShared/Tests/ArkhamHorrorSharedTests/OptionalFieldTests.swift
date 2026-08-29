@testable import ArkhamHorrorShared
import Foundation
import Testing

/// A minimal host type exercising `OptionalField`'s decode/encode helpers in isolation from
/// any production request type.
private struct OptionalFieldHost: Equatable, Codable {
    let flag: OptionalField<Bool>

    private enum CodingKeys: String, CodingKey { case flag }

    init(flag: OptionalField<Bool>) {
        self.flag = flag
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flag = try OptionalField<Bool>.decode(from: container, forKey: .flag)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try flag.encode(to: &container, forKey: .flag)
    }
}

@Suite("OptionalField")
struct OptionalFieldTests {
    @Test("An absent key decodes to .absent")
    func decodesAbsent() throws {
        let host = try JSONDecoder().decode(OptionalFieldHost.self, from: Data("{}".utf8))
        #expect(host.flag == .absent)
        #expect(host.flag.valueOrNil == nil)
    }

    @Test("An explicit null decodes to .null, distinct from absent")
    func decodesNull() throws {
        let host = try JSONDecoder().decode(
            OptionalFieldHost.self,
            from: Data(#"{"flag": null}"#.utf8)
        )
        #expect(host.flag == .null)
        #expect(host.flag != .absent)
        #expect(host.flag.valueOrNil == nil)
    }

    @Test("A present value decodes to .value")
    func decodesValue() throws {
        let host = try JSONDecoder().decode(
            OptionalFieldHost.self,
            from: Data(#"{"flag": true}"#.utf8)
        )
        #expect(host.flag == .value(true))
        #expect(host.flag.valueOrNil == true)
    }

    @Test(".absent omits the key entirely on encode")
    func encodesAbsentAsOmitted() throws {
        let data = try JSONEncoder().encode(OptionalFieldHost(flag: .absent))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("flag"))
    }

    @Test(".null encodes an explicit JSON null, not an omitted key")
    func encodesNullExplicitly() throws {
        let data = try JSONEncoder().encode(OptionalFieldHost(flag: .null))
        #expect(String(data: data, encoding: .utf8) == #"{"flag":null}"#)
    }

    @Test(".value encodes the payload")
    func encodesValue() throws {
        let data = try JSONEncoder().encode(OptionalFieldHost(flag: .value(false)))
        #expect(String(data: data, encoding: .utf8) == #"{"flag":false}"#)
    }
}
