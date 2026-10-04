@testable import ArkhamHorrorShared
import CoreGraphics
import Foundation
#if os(macOS)
    import AppKit
    import SwiftUI
#endif
import Testing

@Suite("Board location enemy tile layout")
struct BoardLocationEnemyTileLayoutTests {
    @Test("Minimum zoom can reserve room for an enemy action control")
    func minimumZoomCanReserveRoomForEnemyActionControl() {
        #expect(
            BoardLocationEnemyTileMetrics.regular.minimumCellSize
                == CGSize(width: 90, height: 70)
        )
        #expect(
            BoardLocationEnemyTileMetrics.regular.minimumCellSize(hasLinkedEnemyActions: true)
                == CGSize(width: 90, height: 92)
        )
        #expect(
            BoardLocationEnemyTileMetrics.tvOS.minimumCellSize(hasLinkedEnemyActions: true)
                == CGSize(width: 180, height: 160)
        )
    }

    @Test("Zoom 0.5 still leaves room for an actionable compact enemy indicator")
    func zoomHalfShowsCompactIndicator() {
        #expect(
            decision(zoom: 0.5, headerHeight: 44, enemyCount: 3, metrics: .regular)
                == .compactIndicator
        )
    }

    @Test("Zoom 0.5 offers natural name box height, then reports the clipped height")
    func zoomHalfClampsNaturalNameBoxHeight() {
        let tileGeometry = BoardLocationTileGeometryPlan.plan(
            zoomScale: 0.5,
            hasLinkedEnemyActions: false,
            metrics: .regular
        )
        #expect(tileGeometry.cellSize == CGSize(width: 90, height: 70))
        #expect(tileGeometry.tileSize == CGSize(width: 82, height: 62))

        let uncappedPlan = BoardLocationEnemyTileHeightPlan.plan(
            tileHeight: tileGeometry.tileSize.height,
            measuredHeaderHeight: 86,
            hasEnemies: true,
            hasLinkedEnemyActions: false,
            metrics: .regular
        )
        let drawnHeaderHeight = BoardLocationHeaderSizing.drawnHeight(
            naturalHeight: 86,
            maximumHeight: uncappedPlan.headerMaxHeight
        )
        #expect(uncappedPlan.headerMaxHeight == BoardLocationHeaderSizing.minimumInteractiveHeight)
        #expect(drawnHeaderHeight == BoardLocationHeaderSizing.minimumInteractiveHeight)

        let measuredPlan = BoardLocationEnemyTileHeightPlan.plan(
            tileHeight: tileGeometry.tileSize.height,
            measuredHeaderHeight: drawnHeaderHeight,
            hasEnemies: true,
            hasLinkedEnemyActions: false,
            metrics: .regular
        )
        #expect(measuredPlan.effectiveHeaderHeight == drawnHeaderHeight)
        #expect(measuredPlan.enemyPanelHeight == 14)
    }

    @Test("The view uses the clamping layout instead of fixed-size overflow")
    func boardLocationViewUsesHeaderClampLayout() throws {
        let source = try String(contentsOf: boardLocationBoardViewSourceURL, encoding: .utf8)
        #expect(source.contains("BoardLocationHeaderClampLayout(maximumHeight:"))
        #expect(!source.contains(".fixedSize(horizontal: false, vertical: true)"))
    }

    @Test("Zoom 1 with a measured one-line header shows one chip and overflow")
    func zoomOneOneLineHeaderShowsChipAndOverflow() {
        #expect(
            decision(zoom: 1, headerHeight: 66, enemyCount: 3, metrics: .regular)
                == .chips(visibleCount: 1, hasMore: true)
        )
    }

    @Test("Zoom 1 with a measured two-line header falls back instead of clipping chips")
    func zoomOneTwoLineHeaderShowsCompactIndicator() {
        #expect(
            decision(zoom: 1, headerHeight: 86, enemyCount: 3, metrics: .regular)
                == .compactIndicator
        )
    }

    @Test("Zoom 3 has enough measured space for all compact chips")
    func zoomThreeShowsAllChips() {
        #expect(
            decision(zoom: 3, headerHeight: 86, enemyCount: 3, metrics: .regular)
                == .chips(visibleCount: 3, hasMore: false)
        )
    }

    @Test("tvOS one-line measured header leaves room for chip plus overflow")
    func tvOSOneLineHeaderShowsChipAndOverflow() {
        #expect(
            decision(zoom: 1, headerHeight: 95, enemyCount: 3, metrics: .tvOS)
                == .chips(visibleCount: 1, hasMore: true)
        )
    }

    @Test("tvOS two-line measured header still leaves an actionable compact indicator")
    func tvOSTwoLineHeaderShowsCompactIndicator() {
        #expect(
            decision(zoom: 1, headerHeight: 126, enemyCount: 3, metrics: .tvOS)
                == .compactIndicator
        )
    }

    @Test("tvOS minimum cell with linked action still leaves compact indicator room")
    func tvOSMinimumCellWithLinkedActionShowsCompactIndicator() {
        #expect(
            decision(
                zoom: 1,
                headerHeight: 126,
                enemyCount: 3,
                metrics: .tvOS,
                hasLinkedEnemyActions: true
            ) == .compactIndicator
        )
    }

    #if os(macOS)
        @MainActor
        @Test("Writes visual snapshots for location tile zoom levels")
        func writesVisualSnapshotsForLocationTileZoomLevels() throws {
            let records = try [CGFloat(0.5), 1, 3].map { try writeVisualSnapshot(zoom: $0) }
            let measurementsURL = URL(fileURLWithPath: "/tmp/arkham-task-1.7-location-tile-measurements.txt")
            try records
                .map { record in
                    "zoom=\(record.zoom) path=\(record.path) tile=\(record.tileSize.width)x\(record.tileSize.height) header=\(record.headerHeight) enemyPanel=\(record.enemyPanelHeight)"
                }
                .joined(separator: "\n")
                .appending("\n")
                .write(to: measurementsURL, atomically: true, encoding: .utf8)
            #expect(FileManager.default.fileExists(atPath: measurementsURL.path))
            #expect(records.map(\.headerHeight) == [44, 66, 66])
            #expect(records.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }
    #endif

    private var boardLocationBoardViewSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ArkhamHorrorShared/Presentation/Board/BoardLocationBoardView.swift")
    }

    private func decision(
        zoom: CGFloat,
        headerHeight: CGFloat,
        enemyCount: Int,
        metrics: BoardLocationEnemyTileMetrics,
        hasLinkedEnemyActions: Bool = false
    ) -> BoardLocationEnemyTileLayoutDecision {
        let tileGeometry = BoardLocationTileGeometryPlan.plan(
            zoomScale: zoom,
            hasLinkedEnemyActions: hasLinkedEnemyActions,
            metrics: metrics
        )
        let uncappedPlan = BoardLocationEnemyTileHeightPlan.plan(
            tileHeight: tileGeometry.tileSize.height,
            measuredHeaderHeight: headerHeight,
            hasEnemies: enemyCount > 0,
            hasLinkedEnemyActions: hasLinkedEnemyActions,
            metrics: metrics
        )
        let drawnHeaderHeight = BoardLocationHeaderSizing.drawnHeight(
            naturalHeight: headerHeight,
            maximumHeight: uncappedPlan.headerMaxHeight
        )
        let heightPlan = BoardLocationEnemyTileHeightPlan.plan(
            tileHeight: tileGeometry.tileSize.height,
            measuredHeaderHeight: drawnHeaderHeight,
            hasEnemies: enemyCount > 0,
            hasLinkedEnemyActions: hasLinkedEnemyActions,
            metrics: metrics
        )
        return BoardLocationEnemyTileLayout.decision(
            enemyCount: enemyCount,
            availableWidth: tileGeometry.tileSize.width,
            availableHeight: heightPlan.enemyPanelHeight,
            metrics: metrics
        )
    }

    #if os(macOS)
        @MainActor
        private func writeVisualSnapshot(zoom: CGFloat) throws -> BoardLocationTileSnapshotRecord {
            let metrics = BoardLocationEnemyTileMetrics.regular
            let tileGeometry = BoardLocationTileGeometryPlan.plan(
                zoomScale: zoom,
                hasLinkedEnemyActions: false,
                metrics: metrics
            )
            let uncappedPlan = BoardLocationEnemyTileHeightPlan.plan(
                tileHeight: tileGeometry.tileSize.height,
                measuredHeaderHeight: BoardLocationTileSnapshotView.naturalHeaderHeight,
                hasEnemies: true,
                hasLinkedEnemyActions: false,
                metrics: metrics
            )
            let headerHeight = BoardLocationHeaderSizing.drawnHeight(
                naturalHeight: BoardLocationTileSnapshotView.naturalHeaderHeight,
                maximumHeight: uncappedPlan.headerMaxHeight
            )
            let heightPlan = BoardLocationEnemyTileHeightPlan.plan(
                tileHeight: tileGeometry.tileSize.height,
                measuredHeaderHeight: headerHeight,
                hasEnemies: true,
                hasLinkedEnemyActions: false,
                metrics: metrics
            )
            let zoomLabel = zoom == 0.5 ? "0_5" : String(Int(zoom))
            let path = "/tmp/arkham-task-1.7-location-tile-zoom-\(zoomLabel).png"
            let renderer = ImageRenderer(content: BoardLocationTileSnapshotView(
                zoomScale: zoom,
                headerHeight: headerHeight,
                enemyPanelHeight: heightPlan.enemyPanelHeight
            ))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try pngData.write(to: URL(fileURLWithPath: path), options: .atomic)
            return BoardLocationTileSnapshotRecord(
                zoom: zoom,
                path: path,
                tileSize: tileGeometry.tileSize,
                headerHeight: headerHeight,
                enemyPanelHeight: heightPlan.enemyPanelHeight
            )
        }
    #endif
}

#if os(macOS)
    private struct BoardLocationTileSnapshotRecord: Equatable {
        let zoom: CGFloat
        let path: String
        let tileSize: CGSize
        let headerHeight: CGFloat
        let enemyPanelHeight: CGFloat
    }

    private struct BoardLocationTileSnapshotView: View {
        static let naturalHeaderHeight: CGFloat = 66

        let zoomScale: CGFloat
        let headerHeight: CGFloat
        let enemyPanelHeight: CGFloat
        @FocusState private var focusedID: SemanticFocusID?

        private var metrics: BoardLocationEnemyTileMetrics {
            .regular
        }

        private var tileSize: CGSize {
            BoardLocationTileGeometryPlan.plan(
                zoomScale: zoomScale,
                hasLinkedEnemyActions: false,
                metrics: metrics
            ).tileSize
        }

        private var enemies: [BoardEnemyNode] {
            [
                enemy("000000000701", name: "Ghoul Minion"),
                enemy("000000000702", name: "Ravenous Ghoul"),
                enemy("000000000703", name: "Swarm of Rats"),
            ]
        }

        var body: some View {
            VStack(spacing: metrics.verticalSpacing) {
                BoardLocationHeaderClampLayout(maximumHeight: headerHeight) {
                    locationHeader
                }
                .clipped()
                enemyPanel
            }
            .frame(width: tileSize.width, height: tileSize.height, alignment: .top)
            .padding(12)
            .background(Color.black.opacity(0.88))
        }

        private var locationHeader: some View {
            BoardEntityTile(
                id: BoardFocusID.location(BoardTestFixtures.locationID("000000000700")),
                accessibilityLabel: "Study, 2 clues, 3 enemies",
                isFocused: false,
                focusBinding: $focusedID,
                onOutcome: { _, _ in }
            ) {
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 2) {
                        locationTitle
                        HStack(spacing: 4) {
                            BoardStatBadge(systemImage: "sparkles", value: "2")
                            BoardStatBadge(systemImage: "figure.walk", value: "3")
                        }
                    }
                    locationTitle
                }
            }
        }

        private var locationTitle: some View {
            Text("Study")
                .font(.subheadline.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
                .foregroundStyle(ArkhamTheme.bone)
        }

        @ViewBuilder private var enemyPanel: some View {
            let decision = BoardLocationEnemyTileLayout.decision(
                enemyCount: enemies.count,
                availableWidth: tileSize.width,
                availableHeight: enemyPanelHeight,
                metrics: metrics
            )
            switch decision {
            case .hidden:
                EmptyView()
            case .compactIndicator:
                BoardEnemyOverflowMenu(
                    label: "\(enemies.count)",
                    labelStyle: .compactBadge,
                    enemies: enemies,
                    choiceLinks: [:],
                    onLinkedChoice: { _ in }
                )
            case .summaryButton:
                BoardEnemyOverflowMenu(
                    label: "\(enemies.count) enemies",
                    enemies: enemies,
                    choiceLinks: [:],
                    onLinkedChoice: { _ in }
                )
            case let .chips(visibleCount, hasMore):
                HStack(spacing: metrics.horizontalSpacing) {
                    ForEach(Array(enemies.prefix(visibleCount))) { enemy in
                        BoardEnemyTileChipView(
                            enemy: enemy,
                            linkedChoices: [],
                            onLinkedChoice: { _ in }
                        )
                    }
                    if hasMore {
                        BoardEnemyOverflowMenu(
                            label: "+\(enemies.count - visibleCount) more",
                            enemies: enemies,
                            choiceLinks: [:],
                            onLinkedChoice: { _ in }
                        )
                    }
                }
            }
        }

        private func enemy(_ suffix: String, name: String) -> BoardEnemyNode {
            BoardEnemyNode(
                id: BoardTestFixtures.enemyID(suffix),
                cardCode: nil,
                displayName: name,
                fight: nil,
                health: nil,
                evade: nil,
                damage: nil,
                horror: nil,
                attackDamage: nil,
                attackHorror: nil,
                exhausted: false,
                engagedInvestigatorID: nil,
                locationID: BoardTestFixtures.locationID("000000000700"),
                tokenCounts: []
            )
        }
    }
#endif
