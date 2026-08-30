@testable import ArkhamHorrorShared
import Testing

/// ``AssetError``'s documented equality contract: cases carrying a fixed,
/// semantically meaningful discriminator (``AssetError/invalidIdentifier(field:)``'s
/// field name) participate in equality, while cases carrying genuinely
/// free-form diagnostic text (``AssetError/transportFailure(_:)``,
/// ``AssetError/cachePersistenceFailed(_:)``,
/// ``AssetError/configurationFailure(_:)``) do not. These tests exist so a
/// future change to either the doc comment or the `Equatable`
/// implementation can't silently drift the two apart again.
struct AssetErrorEqualityTests {
    @Test("invalidIdentifier with the same field name compares equal")
    func invalidIdentifierSameFieldEqual() {
        #expect(
            AssetError.invalidIdentifier(field: "cardCode")
                == AssetError.invalidIdentifier(field: "cardCode")
        )
    }

    @Test("invalidIdentifier with different field names compares unequal")
    func invalidIdentifierDifferentFieldNotEqual() {
        #expect(
            AssetError.invalidIdentifier(field: "cardCode")
                != AssetError.invalidIdentifier(field: "locale")
        )
    }

    @Test("transportFailure ignores its diagnostic payload in equality")
    func transportFailureIgnoresDiagnosticPayload() {
        #expect(
            AssetError.transportFailure("timed out")
                == AssetError.transportFailure("connection reset")
        )
    }

    @Test("cachePersistenceFailed ignores its diagnostic payload in equality")
    func cachePersistenceFailedIgnoresDiagnosticPayload() {
        #expect(
            AssetError.cachePersistenceFailed("rename failed")
                == AssetError.cachePersistenceFailed("fsync failed")
        )
    }

    @Test("configurationFailure ignores its diagnostic payload in equality")
    func configurationFailureIgnoresDiagnosticPayload() {
        #expect(
            AssetError.configurationFailure("missing digest table")
                == AssetError.configurationFailure("corrupt digest table")
        )
    }
}
