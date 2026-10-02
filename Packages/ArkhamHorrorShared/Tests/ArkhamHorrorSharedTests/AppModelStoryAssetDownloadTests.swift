@testable import ArkhamHorrorShared
import Foundation
import Testing

@MainActor
extension AppModelStoryAssetTests {
    func firstGatheringImageReference(
        in presentation: BasicChoicePromptPresentation
    ) throws -> StoryAssetReference {
        let entry = try #require(firstGatheringListEntry(in: presentation))
        guard case let .nodes(nodes) = entry else { throw TestFailure() }
        #expect(nodes.first == .text("Collect these encounter sets: "))
        let references = nodes.compactMap { node -> StoryAssetReference? in
            guard case let .image(reference) = node else { return nil }
            return reference
        }
        let reference = try #require(references.first)
        #expect(reference.accessibleDescription == "The Gathering encounter set symbol")
        return reference
    }

    func waitForImageLoadSettled(
        _ loader: AssetImageLoader,
        timeoutNanoseconds: UInt64 = 10_000_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while case .loading = loader.state, DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func enqueuePNGResponse(_ transport: FakeAssetTransport, for url: URL) async {
        await transport.enqueue(
            .success(.success(AssetHTTPResponse(
                body: AssetImageFixtureBuilder.validPNG(width: 4, height: 4),
                contentType: "image/png",
                etag: nil,
                lastModified: nil
            ))),
            for: url
        )
    }

    @Test("Failed PNG download leaves AppModel story answerable and image retry recovers")
    func pngDownloadFailureUsesImageSpecificRetry() async throws {
        try await withModel { model, documents, _, _, factory in
            let gameID = try installGatheringReadPrompt(on: model, profile: documents.profile)
            var prompt = try #require(model.basicChoicePresentation(for: gameID))
            #expect(prompt.canSubmit)
            #expect(prompt.catalogRetry == nil)
            let reference = try firstGatheringImageReference(in: prompt)
            let key = try #require(reference.assetKey)
            let cache = try #require(model.assetCacheService)
            let transport = try #require(factory.transport)
            let url = try #require(
                AssetLocator.candidates(for: key, digest: FakeDigestLookup())
                    .first?.url(base: key.source)
            )

            await transport.enqueue(.failure(AssetError.unexpectedStatus(503)), for: url)
            let loader = AssetImageLoader(cacheService: cache)
            loader.load(key, accessibleDescription: reference.accessibleDescription)
            await waitForImageLoadSettled(loader)
            guard case let .failure(error, description) = loader.state else {
                Issue.record("Expected failed image load, got \(loader.state)")
                return
            }
            #expect(error == .unexpectedStatus(503))
            #expect(description == "The Gathering encounter set symbol")
            prompt = try #require(model.basicChoicePresentation(for: gameID))
            #expect(prompt.canSubmit)
            #expect(prompt.catalogRetry == nil)
            _ = try firstGatheringImageReference(in: prompt)

            await enqueuePNGResponse(transport, for: url)
            loader.load(key, accessibleDescription: reference.accessibleDescription)
            await waitForImageLoadSettled(loader)
            guard case let .success(_, recoveredDescription) = loader.state else {
                Issue.record("Expected recovered image load, got \(loader.state)")
                return
            }
            #expect(recoveredDescription == "The Gathering encounter set symbol")
            #expect(await transport.callCount(for: url) == 2)
            prompt = try #require(model.basicChoicePresentation(for: gameID))
            #expect(prompt.canSubmit)
            #expect(prompt.catalogRetry == nil)
        }
    }
}
