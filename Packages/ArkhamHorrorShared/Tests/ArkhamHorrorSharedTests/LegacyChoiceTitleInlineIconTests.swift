@testable import ArkhamHorrorShared
import Foundation
import Testing

/// Choice prompts without the server's question presentation (the legacy path) speak and
/// parse catalog-sourced titles into icon nodes and leave names untouched.
@Suite("Legacy choice title inline icons")
struct LegacyChoiceTitleInlineIconTests {
    private let ownerID = BoardTestFixtures.playerID()

    private func fixtureQuestion() throws -> BasicChoiceQuestion {
        let url = try #require(
            Bundle.module.url(
                forResource: "question-mulligan",
                withExtension: "json",
                subdirectory: "Fixtures/Contract"
            )
        )
        let payload = try ContractJSON.decode(
            BasicChoiceQuestionPayload.self,
            from: Data(contentsOf: url)
        )
        return try #require(payload.supportedQuestion)
    }

    private func projection(locations: [(LocationID, Location)] = []) -> BoardProjection {
        let investigatorID = BoardTestFixtures.investigatorID("c01001")
        return BoardProjectionBuilder.makeProjection(from: BoardTestFixtures.snapshot(
            locations: locations,
            investigators: [
                investigatorID: BoardTestFixtures.investigator(
                    id: investigatorID,
                    hand: [],
                    playerID: ownerID
                ),
            ],
            playerOrder: [investigatorID],
            activeInvestigatorID: investigatorID,
            leadInvestigatorID: investigatorID
        ))
    }

    private func prompt(
        _ question: BasicChoiceQuestion,
        resolutions: [Int: BasicChoiceLabelResolution]
    ) -> BasicChoicePromptPresentation {
        BasicChoicePromptPresentation(
            identity: BasicChoicePromptIdentity(
                gameID: BoardTestFixtures.gameID(),
                ownerID: ownerID,
                questionVersion: 4,
                rawQuestion: question.rawValue,
                sessionAttemptID: nil,
                connectionID: nil
            ),
            question: .supported(question),
            choiceLabelResolutions: resolutions,
            readOnlyReason: nil,
            actionPhase: nil,
            actionChoiceIndex: nil,
            serverFeedback: nil
        )
    }

    @Test("Catalog legacy titles are spoken-ized and parsed into icon and emphasis nodes")
    func catalogLegacyTitlesAreSpokenAndParsed() throws {
        struct Case {
            let label: String
            let title: String
            let nodes: [StoryNode]?

            init(_ label: String, _ title: String, _ nodes: [StoryNode]?) {
                self.label = label
                self.title = title
                self.nodes = nodes
            }
        }
        let cases: [Case] = [
            Case(
                "Reveal {skull} now",
                "Reveal Skull now",
                [.text("Reveal "), .semanticIcon(.chaosToken(.skull)), .text(" now")]
            ),
            Case("Choose {neutral} {future}", "Choose {neutral} {future}", nil),
            Case(
                "Take _1_ {asterisk}",
                "Take 1 *",
                [.text("Take "), .emphasis(.bold, [.text("1")]), .text(" *")]
            ),
            Case("Keep tdc_rune_m and a_b", "Keep tdc_rune_m and a_b", nil),
        ]
        let question = try fixtureQuestion()
        let choice = question.choices[0]
        let projection = projection()
        for testCase in cases {
            let resolved = prompt(question, resolutions: [0: .resolved(testCase.label)])
                .resolvedChoiceLabel(for: choice, in: projection)
            let comment = Comment(rawValue: testCase.label)
            #expect(resolved.title == testCase.title, comment)
            #expect(resolved.accessibilityLabel == testCase.title, comment)
            #expect(resolved.titleNodes == testCase.nodes, comment)
        }
    }

    @Test("A resolved catalog label with inline nodes keeps those nodes")
    func resolvedInlineNodesAreReused() throws {
        let question = try fixtureQuestion()
        let nodes: [StoryNode] = [.text("Spend "), .icon("perPlayer"), .text(" clues")]
        let resolved = prompt(
            question,
            resolutions: [0: .resolved(BasicChoiceResolvedLabelText(
                title: "Spend Per player clues",
                inlineNodes: nodes
            ))]
        ).resolvedChoiceLabel(for: question.choices[0], in: projection())

        #expect(resolved.title == "Spend Per player clues")
        #expect(resolved.titleNodes == nodes)
        #expect(resolved.accessibilityLabel == "Spend Per player clues")
    }

    @Test("Resolved inline nodes keep their plain title even when it looks like markup")
    func resolvedInlineNodesKeepTheirPlainTitle() throws {
        let question = try fixtureQuestion()
        let nodes: [StoryNode] = [.text("Spend *all* "), .icon("perPlayer"), .text(" clues")]
        let resolved = prompt(
            question,
            resolutions: [0: .resolved(BasicChoiceResolvedLabelText(
                title: "Spend *all* Per player clues",
                inlineNodes: nodes
            ))]
        ).resolvedChoiceLabel(for: question.choices[0], in: projection())

        #expect(resolved.title == "Spend *all* Per player clues")
        #expect(resolved.titleNodes == nodes)
        #expect(resolved.accessibilityLabel == "Spend *all* Per player clues")
    }

    private func catalogResolver(_ nodes: [LocaleCatalogNode]) -> LocaleCatalogResolver {
        let digest = String(repeating: "a", count: 64)
        let manifest = LocaleCatalogManifest(
            catalogRevision: "1.synthetic000000000000000000000000",
            defaultLocale: "en",
            locales: [LocaleCatalogLocaleRecord(
                locale: "en", fallback: nil,
                chunks: [LocaleCatalogChunkDescriptor(
                    pack: "story", path: LocaleCatalogGrammar.chunkPath(forDigest: digest),
                    bytes: 1, sha256: digest, keys: 1, unsupportedKeys: 0
                )],
                keys: 1, bytes: 1
            )],
            languageResolution: ["en": "en"],
            totals: LocaleCatalogTotals(
                locales: 1, chunks: 1, bytes: 1, keys: 1, unsupportedKeys: 0
            )
        )
        let chunk = LocaleCatalogChunk(
            locale: "en", fallback: nil, pack: "story",
            entries: ["label.doneWithMulligan": .message(nodes: nodes, variables: [])]
        )
        return LocaleCatalogResolver(snapshot: LocaleCatalogSnapshot(
            identity: LocaleCatalogIdentity(
                endpoint: URL(string: "https://catalog.example.test/locale-catalog/manifest.json")!,
                catalogRevision: manifest.catalogRevision,
                locale: "en",
                manifestSha256: String(repeating: "b", count: 64)
            ),
            manifest: manifest,
            chunks: [LocaleCatalogChunkKey(locale: "en", pack: "story"): chunk]
        ))
    }

    @Test("Icon-free titles rendered by the production resolver keep their literal text")
    func productionRenderedLiteralTitlesAreNotReparsed() throws {
        let question = try fixtureQuestion()
        // Catalog text is already rendered: literal `*all*` text, a bold node that flattens
        // to plain text, and a literal `*` (the web's `{asterisk}` escape, already applied).
        let label = try StoryNarrativeLocalization.resolveProductionChoiceLabelRich(
            "$label.doneWithMulligan",
            resolver: catalogResolver([
                .text("Spend *all* clues, "),
                .emphasis(style: .bold, children: [.text("_now_")]),
                .text(" *"),
            ]),
            catalogUnavailability: .catalog(.transportFailure)
        ).get()
        #expect(label == BasicChoiceResolvedLabelText(title: "Spend *all* clues, _now_ *"))

        let resolved = prompt(question, resolutions: [0: .resolved(label)])
            .resolvedChoiceLabel(for: question.choices[0], in: projection())

        #expect(resolved.title == "Spend *all* clues, _now_ *")
        #expect(resolved.titleNodes == nil)
        #expect(resolved.accessibilityLabel == "Spend *all* clues, _now_ *")
    }

    @Test("Raw placeholders in a resolved text variable render as icons with spoken names")
    func productionVariableRawPlaceholdersAreParsed() throws {
        let question = try fixtureQuestion()
        let label = try StoryNarrativeLocalization.resolveProductionChoiceLabelRich(
            "$label.doneWithMulligan name=s:\"Chamber of Records [tdc_rune_m] {perPlayer}\"",
            resolver: catalogResolver([
                .text("Done at "),
                .variable(name: "name", source: .named, role: .text),
            ]),
            catalogUnavailability: .catalog(.transportFailure)
        ).get()
        #expect(label == BasicChoiceResolvedLabelText(
            title: "Done at Chamber of Records [tdc_rune_m] {perPlayer}"
        ))

        let resolved = prompt(question, resolutions: [0: .resolved(label)])
            .resolvedChoiceLabel(for: question.choices[0], in: projection())

        #expect(resolved.title == "Done at Chamber of Records Rune M Per player")
        #expect(resolved.titleNodes == [
            .text("Done at Chamber of Records "), .icon("rune-M"), .text(" "),
            .icon("perPlayer"),
        ])
        #expect(resolved.accessibilityLabel == "Done at Chamber of Records Rune M Per player")
    }

    @Test("Raw placeholder detection covers icons, runes, escapes and footnotes, not emphasis")
    func rawPlaceholderDetection() {
        let cases: [(String, Bool)] = [
            ("Reveal {skull}", true),
            ("At [tdc_rune_m]", true),
            ("Take 1 {asterisk}", true),
            ("Keep {underscore}", true),
            ("Wrote 1927[^5]", true),
            ("Keep [^x] and [^]", false),
            ("Choose {neutral}", false),
            ("Spend *a* clue", false),
            ("Keep a_b", false),
            ("Done replacing cards", false),
        ]
        for (text, expected) in cases {
            #expect(
                StoryIconInlineParser.containsRawPlaceholder(text) == expected,
                Comment(rawValue: text)
            )
        }
    }

    @Test("Legacy location names keep their literal * and _ characters and no nodes")
    func nonCatalogLegacyTitlesStayLiteral() throws {
        let question = try fixtureQuestion()
        let locationID = BoardTestFixtures.locationID("000000000101")
        let projection = projection(locations: [
            (locationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                id: locationID,
                label: "Rue *Orsay* _Annex_"
            ))),
        ])
        let choice = BasicChoice(
            index: 1,
            rawValue: .null,
            content: .chooseLocation(locationID: locationID, messages: [])
        )
        let resolved = prompt(question, resolutions: [1: .resolved("{skull} _bold_")])
            .resolvedChoiceLabel(for: choice, in: projection)

        #expect(resolved.title == "Rue *Orsay* _Annex_")
        #expect(resolved.titleNodes == nil)
    }

    @Test("Prompts differing only in legacy title share a prompt key and stay actionable")
    func legacyTitleDoesNotChangePromptKeyOrActionability() throws {
        let question = try fixtureQuestion()
        let projection = projection()
        let raw = prompt(question, resolutions: [0: .resolved("Done at [tdc_rune_m] {perPlayer}")])
        let plain = prompt(question, resolutions: [0: .resolved("Done replacing cards")])

        #expect(raw.displayTitle(for: question.choices[0], in: projection)
            != plain.displayTitle(for: question.choices[0], in: projection))
        #expect(raw.identity.promptKey == plain.identity.promptKey)
        #expect(raw.isChoiceActionable(question.choices[0], in: projection))
        #expect(plain.isChoiceActionable(question.choices[0], in: projection))
        #expect(raw.displayTitle(for: question.choices[0], in: projection)
            == "Done at Rune M Per player")
    }
}

/// Footnote references (TASK-1.22.5) in legacy titles.
extension LegacyChoiceTitleInlineIconTests {
    @Test("A footnote in a resolved text variable renders a marker and speaks \"footnote N\"")
    func productionVariableFootnoteIsParsed() throws {
        let question = try fixtureQuestion()
        let label = try StoryNarrativeLocalization.resolveProductionChoiceLabelRich(
            "$label.doneWithMulligan name=s:\"Wormius 1927[^5] {perPlayer}\"",
            resolver: catalogResolver([
                .text("Done at "),
                .variable(name: "name", source: .named, role: .text),
            ]),
            catalogUnavailability: .catalog(.transportFailure)
        ).get()
        #expect(label == BasicChoiceResolvedLabelText(
            title: "Done at Wormius 1927[^5] {perPlayer}"
        ))

        let resolved = prompt(question, resolutions: [0: .resolved(label)])
            .resolvedChoiceLabel(for: question.choices[0], in: projection())

        #expect(resolved.title == "Done at Wormius 19275 Per player")
        #expect(resolved.titleNodes == [
            .text("Done at Wormius 1927"), .footnoteMarker("5"), .text(" "),
            .icon("perPlayer"),
        ])
        #expect(
            resolved.accessibilityLabel == "Done at Wormius 1927 footnote 5 Per player"
        )
    }

    @Test("A legacy no-envelope title speaks icons by name and footnotes as \"footnote N\"")
    func legacyNoEnvelopeAccessibilityLabelSpeaksIconsAndFootnotes() throws {
        let question = try fixtureQuestion()
        let locationID = BoardTestFixtures.locationID("000000000101")
        let projection = projection(locations: [
            (locationID, .ordinary(BoardTestFixtures.ordinaryLocation(
                id: locationID,
                label: "Archive {skull} 1927[^5]"
            ))),
        ])
        let choice = BasicChoice(
            index: 1,
            rawValue: .null,
            content: .chooseLocation(locationID: locationID, messages: [])
        )
        let prompt = prompt(question, resolutions: [:])
        let resolved = prompt.resolvedChoiceLabel(for: choice, in: projection)

        #expect(resolved.title == "Archive {skull} 1927[^5]")
        #expect(resolved.titleNodes == nil)
        #expect(resolved.accessibilityLabel == "Archive Skull 1927 footnote 5")
        #expect(
            prompt.accessibilityLabel(for: choice, in: projection)
                == "Archive Skull 1927 footnote 5"
        )
    }
}
