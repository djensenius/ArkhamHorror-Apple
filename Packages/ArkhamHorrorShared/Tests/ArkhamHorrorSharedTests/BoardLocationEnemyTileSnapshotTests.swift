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
        @Test("Writes visual snapshots for location tile zoom levels")
        func writesVisualSnapshotsForLocationTileZoomLevels() throws {
            let records = try [CGFloat(0.5), 1, 3].map { try writeVisualSnapshot(zoom: $0) }
            let measurementsURL = URL(
                fileURLWithPath: "/tmp/arkham-task-1.7-location-tile-measurements.txt"
            )
            try records
                .map { record in
                    [
                        "zoom=\(record.zoom)",
                        "path=\(record.path)",
                        "tile=\(record.tileSize.width)x\(record.tileSize.height)",
                        "header=\(record.headerHeight)",
                        "enemyPanel=\(record.enemyPanelHeight)",
                    ].joined(separator: " ")
                }
                .joined(separator: "\n")
                .appending("\n")
                .write(to: measurementsURL, atomically: true, encoding: .utf8)
            #expect(FileManager.default.fileExists(atPath: measurementsURL.path))
            #expect(records.map(\.headerHeight) == [44, 66, 66])
            #expect(records.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        }

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
    }

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
                onOutcome: { _, _ in },
                content: {
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
            )
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
