#if os(macOS)
    import AppKit
    @testable import ArkhamHorrorShared
    import CoreGraphics
    import Foundation
    import SwiftUI
    import Testing

    @Suite("Board location enemy tile snapshots")
    struct BoardLocationEnemyTileSnapshotTests {
        @MainActor
        @Test("Writes real board location snapshots for location tile zoom levels")
        func writesRealBoardLocationSnapshotsForZoomLevels() throws {
            let cases = [
                BoardLocationSnapshotCase(label: "zoom-0_5", zoom: 0.5, enemyCount: 3),
                BoardLocationSnapshotCase(label: "zoom-1", zoom: 1, enemyCount: 3),
                BoardLocationSnapshotCase(label: "zoom-3", zoom: 3, enemyCount: 3),
                BoardLocationSnapshotCase(label: "zoom-1-no-enemies", zoom: 1, enemyCount: 0),
            ]
            let records = try cases.map { try writeVisualSnapshot(testCase: $0) }
            let measurementsURL = URL(
                fileURLWithPath: "/tmp/arkham-task-1.7-location-tile-measurements.txt"
            )
            try records
                .map(\.description)
                .joined(separator: "\n")
                .appending("\n")
                .write(to: measurementsURL, atomically: true, encoding: .utf8)
            #expect(FileManager.default.fileExists(atPath: measurementsURL.path))
            #expect(records.allSatisfy { record in
                abs(record.headerDrawnHeight - record.measuredHeaderHeight) <= 1
            })
            let minimumZoomRecord = try #require(records.first { $0.label == "zoom-0_5" })
            #expect(minimumZoomRecord.measuredHeaderHeight <= 45)
            #expect(minimumZoomRecord.headerDrawnHeight <= 45)
            #expect(records.allSatisfy { abs($0.headerMidX - $0.imageWidth / 2) <= 2 })
            #expect(records.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }

        @MainActor
        @Test("Header clamp layout centers a narrow header in a wider tile")
        func headerClampLayoutCentersNarrowHeader() throws {
            let renderer = ImageRenderer(content: BoardLocationHeaderClampProbeView())
            renderer.scale = 2
            let bitmap = try bitmap(from: renderer)
            let bounds = try colorBounds(
                in: bitmap,
                matching: { color in
                    color.red > 200 && color.green < 80 && color.blue < 80
                }
            )
            let minimumX = CGFloat(bounds.minimumX) / renderer.scale
            let maximumX = CGFloat(bounds.maximumX + 1) / renderer.scale
            #expect(minimumX >= 59 && minimumX <= 61)
            #expect(maximumX >= 139 && maximumX <= 141)
            #expect(BoardLocationHeaderSizing.reportedWidth(
                naturalWidth: 80,
                proposedWidth: 200
            ) == 80)
        }

        @Test("Header sizing helper covers nil, below, equal, and above cap")
        func headerSizingHelperCoversClampCases() {
            #expect(BoardLocationHeaderSizing.drawnHeight(
                naturalHeight: 66,
                maximumHeight: nil
            ) == 66)
            #expect(BoardLocationHeaderSizing.drawnHeight(
                naturalHeight: 44,
                maximumHeight: 44
            ) == 44)
            #expect(BoardLocationHeaderSizing.drawnHeight(
                naturalHeight: 40,
                maximumHeight: 44
            ) == 40)
            #expect(BoardLocationHeaderSizing.drawnHeight(
                naturalHeight: 86,
                maximumHeight: 44
            ) == 44)
        }

        @MainActor
        private func writeVisualSnapshot(
            testCase: BoardLocationSnapshotCase
        ) throws -> BoardLocationSnapshotRecord {
            let recorder = BoardLocationHeaderMeasurementRecorder()
            let locationID = BoardTestFixtures.locationID("000000000700")
            let content = BoardLocationBoardSnapshotView(
                locationID: locationID,
                zoomScale: testCase.zoom,
                enemyCount: testCase.enemyCount,
                recorder: recorder
            )
            .background(Color.black)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let bitmap = try bitmap(from: renderer)
            guard let measuredHeaderHeight = recorder.heights[locationID] else {
                throw CocoaError(.fileReadUnknown)
            }
            let zoomPath = "/tmp/arkham-task-1.7-location-tile-\(testCase.label).png"
            try pngData(from: bitmap).write(to: URL(fileURLWithPath: zoomPath), options: .atomic)
            let headerBounds = try colorBounds(in: bitmap, matching: isHeaderBackground)
            let scale = renderer.scale
            return BoardLocationSnapshotRecord(
                label: testCase.label,
                zoom: testCase.zoom,
                enemyCount: testCase.enemyCount,
                path: zoomPath,
                imageWidth: CGFloat(bitmap.pixelsWide) / scale,
                imageHeight: CGFloat(bitmap.pixelsHigh) / scale,
                measuredHeaderHeight: measuredHeaderHeight,
                headerXRange: CGFloat(headerBounds.minimumX) / scale
                    ..< CGFloat(headerBounds.maximumX + 1) / scale,
                headerYRange: CGFloat(headerBounds.minimumY) / scale
                    ..< CGFloat(headerBounds.maximumY + 1) / scale
            )
        }
    }

    @MainActor
    private final class BoardLocationHeaderMeasurementRecorder {
        var heights: [LocationID: CGFloat] = [:]
    }

    private struct BoardLocationSnapshotCase {
        let label: String
        let zoom: CGFloat
        let enemyCount: Int
    }

    private struct BoardLocationSnapshotRecord {
        let label: String
        let zoom: CGFloat
        let enemyCount: Int
        let path: String
        let imageWidth: CGFloat
        let imageHeight: CGFloat
        let measuredHeaderHeight: CGFloat
        let headerXRange: Range<CGFloat>
        let headerYRange: Range<CGFloat>

        var headerMidX: CGFloat {
            (headerXRange.lowerBound + headerXRange.upperBound) / 2
        }

        var headerDrawnHeight: CGFloat {
            headerYRange.upperBound - headerYRange.lowerBound
        }

        var description: String {
            [
                "label=\(label)",
                "zoom=\(zoom)",
                "enemies=\(enemyCount)",
                "path=\(path)",
                "image=\(imageWidth)x\(imageHeight)",
                "header=\(measuredHeaderHeight)",
                "headerX=\(headerXRange.lowerBound)..<\(headerXRange.upperBound)",
                "headerY=\(headerYRange.lowerBound)..<\(headerYRange.upperBound)",
            ].joined(separator: " ")
        }
    }

    private struct BoardLocationBoardSnapshotView: View {
        let locationID: LocationID
        let zoomScale: CGFloat
        let enemyCount: Int
        let recorder: BoardLocationHeaderMeasurementRecorder
        @FocusState private var focusedID: SemanticFocusID?

        private var location: BoardLocationNode {
            BoardLocationNode(
                id: locationID,
                cardCode: BoardTestFixtures.cardCode("c01111"),
                displayLabel: "Study",
                revealed: true,
                symbol: .circle,
                shroudSummary: "2",
                investigateSkill: .intellect,
                clueCount: 2,
                doomCount: 0,
                otherTokenCounts: [],
                investigatorIDs: [],
                enemyCount: enemyCount,
                assetCount: 0,
                eventCount: 0,
                treacheryCount: 0,
                concealedCount: 0,
                connectedLocationIDs: [],
                placementSummary: nil
            )
        }

        private var enemies: [BoardEnemyNode] {
            (0 ..< enemyCount).map { index in
                BoardEnemyNode(
                    id: BoardTestFixtures.enemyID("00000000070\(index + 1)"),
                    cardCode: nil,
                    displayName: ["Ghoul Minion", "Ravenous Ghoul", "Swarm of Rats"][index],
                    fight: nil,
                    health: nil,
                    evade: nil,
                    damage: nil,
                    horror: nil,
                    attackDamage: nil,
                    attackHorror: nil,
                    exhausted: false,
                    engagedInvestigatorID: nil,
                    locationID: locationID,
                    tokenCounts: []
                )
            }
        }

        private var layout: BoardLayout {
            BoardLayout(
                positions: [locationID: BoardGridPosition(column: 0, row: 0)],
                neighbors: [:],
                connections: [],
                columnCount: 1,
                rowCount: 1
            )
        }

        var body: some View {
            BoardLocationBoardView(
                locations: [location],
                enemiesByLocationID: [locationID: enemies],
                choiceLinks: [:],
                layout: layout,
                zoomScale: zoomScale,
                focusedID: focusedID,
                focusBinding: $focusedID,
                onOutcome: { _, _ in },
                onLinkedChoice: { _ in }
            )
            .onPreferenceChange(BoardLocationHeaderHeightPreferenceKey.self) { heights in
                recorder.heights = heights
            }
        }
    }

    private struct BoardLocationHeaderClampProbeView: View {
        var body: some View {
            VStack {
                BoardLocationHeaderClampLayout(maximumHeight: nil) {
                    Color.red.frame(width: 80, height: 44)
                }
            }
            .frame(width: 200, height: 60)
            .background(Color.black)
        }
    }

    private struct PixelColor {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
    }

    private struct PixelBounds {
        let minimumX: Int
        let maximumX: Int
        let minimumY: Int
        let maximumY: Int
    }

    @MainActor
    private func bitmap(from renderer: ImageRenderer<some View>) throws -> NSBitmapImageRep {
        guard let image = renderer.nsImage,
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { throw CocoaError(.fileWriteUnknown) }
        return bitmap
    }

    private func pngData(from bitmap: NSBitmapImageRep) throws -> Data {
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return pngData
    }

    private func colorBounds(
        in bitmap: NSBitmapImageRep,
        matching predicate: (PixelColor) -> Bool
    ) throws -> PixelBounds {
        var minimumX = bitmap.pixelsWide
        var maximumX = 0
        var minimumY = bitmap.pixelsHigh
        var maximumY = 0
        for row in 0 ..< bitmap.pixelsHigh {
            for column in 0 ..< bitmap.pixelsWide {
                let color = pixelColor(in: bitmap, column: column, row: row)
                guard predicate(color) else { continue }
                minimumX = min(minimumX, column)
                maximumX = max(maximumX, column)
                minimumY = min(minimumY, row)
                maximumY = max(maximumY, row)
            }
        }
        guard minimumX <= maximumX, minimumY <= maximumY else {
            throw CocoaError(.fileReadUnknown)
        }
        return PixelBounds(
            minimumX: minimumX,
            maximumX: maximumX,
            minimumY: minimumY,
            maximumY: maximumY
        )
    }

    private func pixelColor(in bitmap: NSBitmapImageRep, column: Int, row: Int) -> PixelColor {
        let color = bitmap.colorAt(x: column, y: row) ?? .clear
        return PixelColor(
            red: Int((color.redComponent * 255).rounded()),
            green: Int((color.greenComponent * 255).rounded()),
            blue: Int((color.blueComponent * 255).rounded()),
            alpha: Int((color.alphaComponent * 255).rounded())
        )
    }

    private func isHeaderBackground(_ color: PixelColor) -> Bool {
        let spread = max(color.red, color.green, color.blue)
            - min(color.red, color.green, color.blue)
        return color.alpha > 200 && spread <= 8 && color.red >= 80 && color.red <= 190
    }
#endif
