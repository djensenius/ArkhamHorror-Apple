@testable import ArkhamHorrorShared
import Foundation
import Testing

extension AssetImageLoaderTests {
    @Test("Catalog images retry visibly, decode real PNGs and reuse the bounded cache")
    func catalogImageRetryAndCache() async throws {
        try await withLoader { loader, transport in
            let reference = StoryAssetReference(
                role: .encounterSet, assetPath: "encounter-sets/rats.png", alt: "Rats",
                source: .hosted
            )
            let key = try #require(reference.assetKey)
            let url = portraitURL(for: key)
            await transport.enqueue(.success(.notFound), for: url)
            loader.load(key, accessibleDescription: reference.accessibleDescription)
            await waitForSettledState(loader)
            #expect(loader.state == .failure(.candidatesExhausted, accessibleDescription: "Rats"))
            await transport.enqueue(.success(.success(AssetHTTPResponse(
                body: AssetImageFixtureBuilder.validPNG(), contentType: "image/png",
                etag: nil, lastModified: nil
            ))), for: url)
            loader.load(key, accessibleDescription: reference.accessibleDescription)
            await waitForSettledState(loader)
            guard case let .success(image, label) = loader.state else {
                Issue.record("Expected a decoded catalog asset, not a placeholder")
                return
            }
            #expect(image.width > 0 && image.height > 0)
            #expect(label == "Rats")
            loader.load(key, accessibleDescription: "Ratten")
            await waitForSettledState(loader)
            guard case .success = loader.state else {
                Issue.record("Expected a cache-backed decoded image")
                return
            }
            #expect(loader.state.accessibleDescription == "Ratten")
            #expect(await transport.callCount(for: url) == 2)
        }
    }

    @Test("A catalog PNG cannot silently succeed with JPEG bytes")
    func catalogImageRejectsWrongFormat() async throws {
        try await withLoader { loader, transport in
            let key = try #require(StoryAssetReference(
                role: .encounterSet, assetPath: "encounter-sets/rats.png", alt: nil, source: .hosted
            ).assetKey)
            let url = portraitURL(for: key)
            await transport.enqueue(.success(.success(AssetHTTPResponse(
                body: AssetImageFixtureBuilder.validJPEG(), contentType: "image/jpeg",
                etag: nil, lastModified: nil
            ))), for: url)
            loader.load(key, accessibleDescription: "Encounter set")
            await waitForSettledState(loader)
            guard case .failure = loader.state else {
                Issue.record("A file/signature mismatch must fail")
                return
            }
            #expect(loader.state.accessibleDescription == "Encounter set")
            #expect(await transport.callCount(for: url) == 1)
        }
    }

    @Test("A disappearing story cancels image work and can retry on reappearance")
    func catalogImageCancellation() async throws {
        try await withLoader { loader, transport in
            let key = try #require(StoryAssetReference(
                role: .encounterSet, assetPath: "encounter-sets/rats.png", alt: nil, source: .hosted
            ).assetKey)
            let url = portraitURL(for: key)
            await transport.hold(url)
            await transport.enqueue(.success(.success(AssetHTTPResponse(
                body: AssetImageFixtureBuilder.validPNG(), contentType: "image/png",
                etag: nil, lastModified: nil
            ))), for: url)
            loader.load(key, accessibleDescription: "Encounter set")
            await transport.waitForCallCount(1, for: url)
            loader.cancel()
            #expect(loader.state == .idle)
            #expect(loader.loadTask == nil)
            await transport.release(url)
            loader.load(key, accessibleDescription: "Encounter set")
            await waitForSettledState(loader)
            guard case .success = loader.state else {
                Issue.record("A cancelled catalog image should be retryable")
                return
            }
        }
    }
}
