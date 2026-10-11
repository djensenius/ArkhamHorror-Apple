/// Runtime loading for the web icon fonts used by story text.
extension AppModel {
    func startWebIconFontLoad(for profile: ServerProfile) {
        webIconFontTask?.cancel()
        webIconFontGeneration += 1
        let generation = webIconFontGeneration
        webIconFontAvailability = WebIconFontAvailability()
        webIconFontFailures = [:]
        isWebIconFontLoading = true
        let loader = webIconFontLoader
        webIconFontTask = Task { [weak self] in
            let report = await loader.loadFonts(for: profile)
            self?.applyWebIconFontReport(report, generation: generation)
        }
    }

    func invalidateWebIconFonts() {
        webIconFontTask?.cancel()
        webIconFontTask = nil
        webIconFontGeneration += 1
        webIconFontAvailability = WebIconFontAvailability()
        webIconFontFailures = [:]
        isWebIconFontLoading = false
    }

    private func applyWebIconFontReport(
        _ report: WebIconFontLoadReport,
        generation: Int
    ) {
        guard generation == webIconFontGeneration else { return }
        webIconFontAvailability = report.availability
        webIconFontFailures = report.failures
        isWebIconFontLoading = false
    }
}
