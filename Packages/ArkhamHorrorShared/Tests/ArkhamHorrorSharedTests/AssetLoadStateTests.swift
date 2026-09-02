@testable import ArkhamHorrorShared
import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite("AssetLoadState")
struct AssetLoadStateTests {
    private func decodedImage(_ payload: Data) throws -> CGImage {
        try AssetImageDecoder.decode(payload)
    }

    @Test("idle carries no accessible description")
    func idleHasNoDescription() {
        #expect(AssetLoadState.idle.accessibleDescription == nil)
    }

    @Test("loading, success, and failure all carry their accessible description")
    func nonIdleStatesCarryDescription() throws {
        let image = try decodedImage(AssetImageFixtureBuilder.validPNG())
        #expect(AssetLoadState.loading(accessibleDescription: "Loading")
            .accessibleDescription == "Loading")
        #expect(AssetLoadState.success(image, accessibleDescription: "Loaded")
            .accessibleDescription == "Loaded")
        #expect(
            AssetLoadState.failure(.candidatesExhausted, accessibleDescription: "Failed")
                .accessibleDescription
                == "Failed"
        )
    }

    @Test("Two .idle states are equal")
    func idleStatesAreEqual() {
        #expect(AssetLoadState.idle == AssetLoadState.idle)
    }

    @Test(".loading states are equal exactly when their descriptions match")
    func loadingStatesEqualByDescription() {
        #expect(
            AssetLoadState.loading(accessibleDescription: "a") == AssetLoadState
                .loading(accessibleDescription: "a")
        )
        #expect(
            AssetLoadState.loading(accessibleDescription: "a") != AssetLoadState
                .loading(accessibleDescription: "b")
        )
    }

    @Test(
        ".success states are equal only for the exact same CGImage instance, not equal-looking data"
    )
    func successStatesRequireIdenticalImageInstance() throws {
        let sharedImage = try decodedImage(AssetImageFixtureBuilder.validPNG())
        let anotherDecodeOfSameBytes = try decodedImage(AssetImageFixtureBuilder.validPNG())

        #expect(
            AssetLoadState.success(sharedImage, accessibleDescription: "x")
                == AssetLoadState.success(sharedImage, accessibleDescription: "x")
        )
        #expect(
            AssetLoadState.success(sharedImage, accessibleDescription: "x")
                != AssetLoadState.success(anotherDecodeOfSameBytes, accessibleDescription: "x")
        )
    }

    @Test(".failure states are equal exactly when both the error and description match")
    func failureStatesEqualByErrorAndDescription() {
        #expect(
            AssetLoadState.failure(.candidatesExhausted, accessibleDescription: "x")
                == AssetLoadState.failure(.candidatesExhausted, accessibleDescription: "x")
        )
        #expect(
            AssetLoadState.failure(.candidatesExhausted, accessibleDescription: "x")
                != AssetLoadState.failure(.contentTypeMismatch, accessibleDescription: "x")
        )
        #expect(
            AssetLoadState.failure(.candidatesExhausted, accessibleDescription: "x")
                != AssetLoadState.failure(.candidatesExhausted, accessibleDescription: "y")
        )
    }

    @Test("States of different cases are never equal to one another")
    func differentCasesAreNeverEqual() throws {
        let image = try decodedImage(AssetImageFixtureBuilder.validPNG())
        #expect(AssetLoadState.idle != AssetLoadState.loading(accessibleDescription: "x"))
        #expect(
            AssetLoadState.loading(accessibleDescription: "x")
                != AssetLoadState.success(image, accessibleDescription: "x")
        )
        #expect(
            AssetLoadState.success(image, accessibleDescription: "x")
                != AssetLoadState.failure(.candidatesExhausted, accessibleDescription: "x")
        )
    }
}
