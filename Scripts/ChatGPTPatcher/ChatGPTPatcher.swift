import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private let expectedBundleIdentifier = "com.openai.codex"
private let savedTargetPathKey = "selectedCodexAppPath"
private let savedDestinationDirectoryPathKey = "patchedCodexDestinationDirectory"
private let updaterRepository = "sebbonit/ChatGPT-Patcher"
private let updaterReleaseAPIURL = URL(string: "https://api.github.com/repos/\(updaterRepository)/releases/latest")!
private let updaterAssetName = "ChatGPT-Patcher-macos.zip"
private let updaterChecksumAssetName = "ChatGPT-Patcher-macos.zip.sha256"

private enum PatchFeature: String, CaseIterable, Identifiable, Hashable {
    case customModelSlider = "custom-model-slider"
    case hideProfileMenuItems = "hide-profile-menu-items"
    case openCodeGoProvider = "opencodego-provider"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .customModelSlider: "Custom Model Slider & Configuration"
        case .hideProfileMenuItems: "Hide Profile Menu Items"
        case .openCodeGoProvider: "OpenCode Go Provider & Models"
        }
    }

    var summary: String {
        switch self {
        case .customModelSlider:
            "Reorder model and reasoning-effort points, hide unused options, and keep your layout saved in Settings."
        case .hideProfileMenuItems:
            "Remove Show pet and Invite a friend from the Codex account menu for a cleaner profile dropdown."
        case .openCodeGoProvider:
            "Add OpenCode Go as a separate per-thread provider while keeping the existing OpenAI slider models."
        }
    }

    var symbolName: String {
        switch self {
        case .customModelSlider: "slider.horizontal.3"
        case .hideProfileMenuItems: "person.crop.circle.badge.minus"
        case .openCodeGoProvider: "point.3.connected.trianglepath.dotted"
        }
    }

    var detailTags: [String] {
        switch self {
        case .customModelSlider: ["Drag to reorder", "Live apply", "Persistent"]
        case .hideProfileMenuItems: ["Show pet", "Invite a friend", "Profile menu"]
        case .openCodeGoProvider: ["Separate provider", "20 models", "OpenCode auth"]
        }
    }
}

private enum StatusLevel {
    case neutral
    case ready
    case working
    case warning
    case error
    case success

    var symbolName: String {
        switch self {
        case .neutral: "info.circle"
        case .ready: "checkmark.circle.fill"
        case .working: "arrow.triangle.2.circlepath"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .success: "checkmark.seal.fill"
        }
    }

    var tint: Color {
        switch self {
        case .neutral: .secondary
        case .ready, .success: .green
        case .working: .accentColor
        case .warning: .orange
        case .error: .red
        }
    }
}

private enum UpdateState: Equatable {
    case checking
    case upToDate
    case available(version: String)
    case downloading(version: String)
    case failed(message: String)
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private struct PreparedUpdate {
    let newAppURL: URL
    let targetURL: URL
    let updateRootURL: URL
}

private enum UpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message): message
        }
    }
}

@main
struct ChatGPTPatcherApp: App {
    @StateObject private var patcher = PatcherViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(patcher)
                .frame(minWidth: 720, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        }
        .defaultSize(width: 820, height: 680)
        .windowResizability(.contentMinSize)
    }
}

private struct AppTarget: Identifiable, Hashable {
    let url: URL
    let displayName: String
    let bundleIdentifier: String?
    let version: String?
    let hasAsar: Bool
    let isReadable: Bool
    let isWritable: Bool
    let isAlreadyPatched: Bool

    var id: String { url.standardizedFileURL.path }

    var isExpectedCodexApp: Bool {
        bundleIdentifier == expectedBundleIdentifier
    }

    var isUsableSource: Bool {
        isExpectedCodexApp && hasAsar && isReadable
    }

    var isPatchableCopy: Bool {
        isExpectedCodexApp && hasAsar && isWritable
    }

    var sourceValidationMessage: String {
        if !hasAsar {
            return "This app does not contain Contents/Resources/app.asar."
        }
        if !isExpectedCodexApp {
            let found = bundleIdentifier ?? "no bundle identifier"
            return "Expected Codex (\(expectedBundleIdentifier)); found \(found)."
        }
        if !isReadable {
            return "The app bundle cannot be read by the current user."
        }
        return "Ready to duplicate and patch"
    }
}

private final class PatcherViewModel: ObservableObject {
    @Published var targets: [AppTarget] = []
    @Published var selectedTarget: AppTarget? {
        didSet {
            if let selectedTarget {
                UserDefaults.standard.set(selectedTarget.url.path, forKey: savedTargetPathKey)
            }

            if !isRunning, oldValue?.id != selectedTarget?.id, !hasExplicitDestination {
                destinationURL = selectedTarget.map { _ in suggestedDestination() }
                lastPatchedCopyURL = nil
                recoverableStagingURL = nil
            }
        }
    }
    @Published var destinationURL: URL? {
        didSet {
            if let destinationURL {
                UserDefaults.standard.set(
                    destinationURL.deletingLastPathComponent().path,
                    forKey: savedDestinationDirectoryPathKey
                )
            }
        }
    }
    @Published var output = ""
    @Published var status = "Looking for ChatGPT…"
    @Published var statusLevel: StatusLevel = .neutral
    @Published var activityLabel = "Copying…"
    @Published var isRunning = false
    @Published var lastPatchedCopyURL: URL?
    @Published var recoverableStagingURL: URL?
    @Published var selectedFeatures: Set<PatchFeature> = Set(PatchFeature.allCases)
    @Published var updateState: UpdateState = .checking

    private var activeProcess: Process?
    private var updateDownloadTask: URLSessionDownloadTask?
    private var latestRelease: GitHubRelease?
    private var hasExplicitDestination = false

    var installedVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    var availableUpdateVersion: String? {
        guard case let .available(version) = updateState else { return nil }
        return version
    }

    var isCheckingForUpdates: Bool {
        if case .checking = updateState { return true }
        return false
    }

    var isDownloadingUpdate: Bool {
        if case .downloading = updateState { return true }
        return false
    }

    var willReplaceDestination: Bool {
        guard let destinationURL, let source = selectedTarget else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && destinationURL.pathExtension.lowercased() == "app"
            && resolvedPath(for: destinationURL) != resolvedPath(for: source.url)
    }

    var confirmationTitle: String {
        willReplaceDestination ? "Replace existing patched copy?" : "Create a patched ChatGPT copy?"
    }

    var confirmationMessage: String {
        let featureList = selectedFeatures
            .sorted { $0.title < $1.title }
            .map(\.title)
            .joined(separator: ", ")
        let selection = "Selected features: \(featureList)."
        let providerNotice = selectedFeatures.contains(.openCodeGoProvider)
            ? " OpenCode Go will be active only inside the patched copy; history remains shared and ~/.codex/config.toml stays unchanged. Quit the stock app before opening the patched copy."
            : ""
        if willReplaceDestination {
            return "\(selection)\(providerNotice) The existing output will remain in place until the new copy has been patched and verified, then it will be replaced. The selected source app will not be changed. macOS may ask the signed copy to reauthorize Keychain access."
        }
        return "\(selection)\(providerNotice) The selected source app will remain unchanged. A separate copy will be created, patched, verified, and signed. macOS may ask it to reauthorize Keychain access."
    }

    var outputToRevealURL: URL? {
        lastPatchedCopyURL ?? recoverableStagingURL
    }

    var canCreatePatchedCopy: Bool {
        guard let source = selectedTarget else { return false }
        return source.isUsableSource
            && !selectedFeatures.isEmpty
            && !isRunning
            && !isAppRunning(at: source.url)
            && destinationValidationMessage(for: source) == nil
    }

    init() {
        refreshTargets()

        if let savedPath = UserDefaults.standard.string(forKey: savedTargetPathKey) {
            let savedTarget = makeTarget(URL(fileURLWithPath: savedPath))
            if savedTarget.hasAsar, !savedTarget.isAlreadyPatched {
                addOrUpdateTarget(savedTarget)
                selectedTarget = savedTarget
            }
        }

        if selectedTarget == nil {
            selectedTarget = targets.first(where: { $0.isUsableSource && !$0.isAlreadyPatched }) ?? targets.first
        }

        if selectedTarget != nil, destinationURL == nil {
            destinationURL = suggestedDestination()
        }

        updateStatus()
        checkForUpdates()
    }

    func checkForUpdates() {
        updateDownloadTask?.cancel()
        latestRelease = nil
        updateState = .checking

        var request = URLRequest(url: updaterReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ChatGPT-Patcher/\(installedVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<GitHubRelease, Error>
            if let error {
                result = .failure(error)
            } else if let httpResponse = response as? HTTPURLResponse,
                      !(200..<300).contains(httpResponse.statusCode) {
                result = .failure(UpdateError.message("GitHub returned HTTP \(httpResponse.statusCode)."))
            } else if let data {
                do {
                    result = .success(try JSONDecoder().decode(GitHubRelease.self, from: data))
                } catch {
                    result = .failure(UpdateError.message("GitHub returned an unreadable release response."))
                }
            } else {
                result = .failure(UpdateError.message("GitHub returned an empty response."))
            }

            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(release):
                    let version = self.normalizedVersion(release.tagName)
                    guard release.assets.contains(where: { $0.name == updaterAssetName }) else {
                        self.updateState = .failed(message: "The latest release does not contain the macOS app zip.")
                        return
                    }
                    self.latestRelease = release
                    self.updateState = self.isVersion(version, newerThan: self.installedVersion)
                        ? .available(version: version)
                        : .upToDate
                case let .failure(error):
                    self.updateState = .failed(message: error.localizedDescription)
                }
            }
        }.resume()
    }

    func installAvailableUpdate() {
        guard !isRunning,
              let release = latestRelease,
              let asset = release.assets.first(where: { $0.name == updaterAssetName }),
              case let .available(version) = updateState else {
            return
        }

        updateState = .downloading(version: version)
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("ChatGPT-Patcher/\(installedVersion)", forHTTPHeaderField: "User-Agent")

        updateDownloadTask = URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            guard let self else { return }
            guard let temporaryURL,
                  error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let message = error?.localizedDescription ?? "GitHub did not return the update archive."
                DispatchQueue.main.async {
                    self.updateState = .failed(message: message)
                }
                return
            }

            do {
                let persistentURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ChatGPT-Patcher-download-\(UUID().uuidString).zip")
                try FileManager.default.moveItem(at: temporaryURL, to: persistentURL)
                self.verifyChecksumAndPrepareUpdate(temporaryURL: persistentURL, release: release)
            } catch {
                DispatchQueue.main.async {
                    self.updateState = .failed(message: "Could not save the downloaded update: \(error.localizedDescription)")
                }
            }
        }
        updateDownloadTask?.resume()
    }

    private func verifyChecksumAndPrepareUpdate(temporaryURL: URL, release: GitHubRelease) {
        let checksumAsset = release.assets.first(where: { $0.name == updaterChecksumAssetName })

        let finish: (Result<String?, Error>) -> Void = { [weak self] checksumResult in
            guard let self else { return }
            let expectedChecksum: String?
            switch checksumResult {
            case let .success(checksum):
                expectedChecksum = checksum
            case let .failure(error):
                try? FileManager.default.removeItem(at: temporaryURL)
                DispatchQueue.main.async {
                    self.updateState = .failed(message: error.localizedDescription)
                }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if let expectedChecksum,
                       !self.archiveMatchesChecksum(at: temporaryURL, expected: expectedChecksum) {
                        throw UpdateError.message("The downloaded update failed its SHA-256 check.")
                    }

                    let preparedUpdate = try self.prepareUpdate(at: temporaryURL, release: release)
                    DispatchQueue.main.async {
                        do {
                            try self.launchUpdateHelper(for: preparedUpdate)
                            self.appendOutput("Downloaded ChatGPT Patcher \(self.normalizedVersion(release.tagName)). The app will restart to finish updating.\n")
                            NSApp.terminate(nil)
                        } catch {
                            self.updateState = .failed(message: error.localizedDescription)
                        }
                    }
                } catch {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    DispatchQueue.main.async {
                        self.updateState = .failed(message: error.localizedDescription)
                    }
                }
            }
        }

        guard let checksumAsset else {
            finish(.success(nil))
            return
        }

        var request = URLRequest(url: checksumAsset.browserDownloadURL)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("ChatGPT-Patcher/\(installedVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data,
                  error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let checksumText = String(data: data, encoding: .utf8),
                  let expectedChecksum = checksumText.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first else {
                finish(.failure(UpdateError.message("Could not download the update checksum.")))
                return
            }
            finish(.success(String(expectedChecksum)))
        }.resume()
    }

    private func prepareUpdate(at temporaryURL: URL, release: GitHubRelease) throws -> PreparedUpdate {
        let fileManager = FileManager.default
        let updateRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ChatGPT-Patcher-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: updateRoot, withIntermediateDirectories: true)

        do {
            let archiveURL = updateRoot.appendingPathComponent(updaterAssetName)
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
            let extractedURL = updateRoot.appendingPathComponent("extracted", isDirectory: true)
            try fileManager.createDirectory(at: extractedURL, withIntermediateDirectories: true)
            try runCommand("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractedURL.path])

            guard let appURL = findUpdaterApp(in: extractedURL),
                  let appBundle = Bundle(url: appURL),
                  appBundle.bundleIdentifier == "local.chatgpt.patcher" else {
                throw UpdateError.message("The downloaded archive does not contain ChatGPT Patcher.")
            }

            let expectedVersion = normalizedVersion(release.tagName)
            let downloadedVersion = (appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? (appBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            guard downloadedVersion.map({ normalizedVersion($0) == expectedVersion }) == true else {
                throw UpdateError.message("The downloaded app version does not match the GitHub release.")
            }

            return PreparedUpdate(
                newAppURL: appURL,
                targetURL: try updateInstallTarget(),
                updateRootURL: updateRoot
            )
        } catch {
            try? fileManager.removeItem(at: updateRoot)
            throw error
        }
    }

    private func launchUpdateHelper(for update: PreparedUpdate) throws {
        let helperURL = update.updateRootURL.appendingPathComponent("install-update.sh")
        let helperScript = """
        #!/bin/bash
        set -euo pipefail
        target="$1"
        new_app="$2"
        update_root="$3"
        sleep 1
        backup="${target}.update-backup"
        rm -rf "$backup"
        if [[ -e "$target" ]]; then
            mv "$target" "$backup"
        fi
        if ! mv "$new_app" "$target"; then
            if [[ -e "$backup" ]]; then mv "$backup" "$target"; fi
            exit 1
        fi
        rm -rf "$backup" "$update_root"
        open "$target"
        """
        try helperScript.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: helperURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperURL.path, update.targetURL.path, update.newAppURL.path, update.updateRootURL.path]
        try process.run()
    }

    private func findUpdaterApp(in directory: URL) -> URL? {
        let directURL = directory.appendingPathComponent("ChatGPT Patcher.app")
        if Bundle(url: directURL)?.bundleIdentifier == "local.chatgpt.patcher" {
            return directURL
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
            if Bundle(url: url)?.bundleIdentifier == "local.chatgpt.patcher" {
                return url
            }
            enumerator.skipDescendants()
        }
        return nil
    }

    private func updateInstallTarget() throws -> URL {
        let fileManager = FileManager.default
        let currentURL = Bundle.main.bundleURL.standardizedFileURL
        let currentParent = currentURL.deletingLastPathComponent()
        if fileManager.isWritableFile(atPath: currentParent.path) {
            return currentURL
        }

        let userApplicationsURL = URL(fileURLWithPath: ("~/Applications" as NSString).expandingTildeInPath)
        try fileManager.createDirectory(at: userApplicationsURL, withIntermediateDirectories: true)
        guard fileManager.isWritableFile(atPath: userApplicationsURL.path) else {
            throw UpdateError.message("The current app folder is not writable, and ~/Applications is unavailable.")
        }
        return userApplicationsURL.appendingPathComponent("ChatGPT Patcher.app")
    }

    private func archiveMatchesChecksum(at url: URL, expected: String) -> Bool {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
                  let actual = output.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
                return false
            }
            return actual.caseInsensitiveCompare(expected.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        } catch {
            return false
        }
    }

    private func runCommand(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.message("Could not unpack the downloaded update.")
        }
    }

    private func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
    }

    private func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        func components(_ value: String) -> [Int] {
            normalizedVersion(value)
                .split(separator: ".", omittingEmptySubsequences: false)
                .map { Int($0.split(whereSeparator: { !$0.isNumber }).first ?? "0") ?? 0 }
        }
        let candidateComponents = components(candidate)
        let installedComponents = components(installed)
        for index in 0..<max(candidateComponents.count, installedComponents.count) {
            let candidatePart = index < candidateComponents.count ? candidateComponents[index] : 0
            let installedPart = index < installedComponents.count ? installedComponents[index] : 0
            if candidatePart != installedPart {
                return candidatePart > installedPart
            }
        }
        return false
    }

    func refreshTargets() {
        let manager = FileManager.default
        var urls = Set<URL>()

        for path in standardCandidatePaths() {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if manager.fileExists(atPath: url.path) {
                urls.insert(url)
            }
        }

        if let launchServicesURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: expectedBundleIdentifier) {
            urls.insert(launchServicesURL.standardizedFileURL)
        }

        for directory in ["/Applications", "~/Applications"] {
            let expandedDirectory = (directory as NSString).expandingTildeInPath
            let directoryURL = URL(fileURLWithPath: expandedDirectory)
            guard let contents = try? manager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for url in contents where url.pathExtension.lowercased() == "app" {
                let bundleIdentifier = Bundle(url: url)?.bundleIdentifier
                if bundleIdentifier == expectedBundleIdentifier {
                    urls.insert(url.standardizedFileURL)
                }
            }
        }

        targets = urls
            .map(makeTarget)
            .sorted { lhs, rhs in
                if lhs.isExpectedCodexApp != rhs.isExpectedCodexApp {
                    return lhs.isExpectedCodexApp
                }
                return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
            }

        if let selectedTarget,
           let refreshed = targets.first(where: { $0.id == selectedTarget.id }) {
            self.selectedTarget = refreshed
        }
    }

    func chooseAnotherApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose the original ChatGPT app"
        panel.message = "This source app will be copied and will not be changed."
        panel.prompt = "Choose source app"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.applicationBundle]

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let target = makeTarget(url)
        addOrUpdateTarget(target)
        selectSource(target)
        updateStatus()
    }

    func selectSource(_ target: AppTarget) {
        selectedTarget = target
        updateStatus()
    }

    func chooseDestination() {
        guard selectedTarget != nil else {
            setStatus("Choose the original ChatGPT app first.", level: .warning)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save patched ChatGPT copy"
        panel.message = "A new app bundle will be created here. The original app will not be changed."
        panel.prompt = "Save patched copy"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.nameFieldStringValue = destinationURL?.lastPathComponent
            ?? suggestedDestination().lastPathComponent

        if let destinationURL {
            panel.directoryURL = destinationURL.deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        destinationURL = normalizedAppURL(url)
        hasExplicitDestination = true
        lastPatchedCopyURL = nil
        recoverableStagingURL = nil
        updateStatus()
    }

    func createPatchedCopy() {
        guard !isRunning else { return }
        guard let source = selectedTarget else {
            setStatus("Choose the original ChatGPT app first.", level: .warning)
            return
        }
        guard source.isUsableSource else {
            setStatus(source.sourceValidationMessage, level: .warning)
            return
        }
        guard !selectedFeatures.isEmpty else {
            setStatus("Select at least one feature to patch.", level: .warning)
            return
        }
        guard !isAppRunning(at: source.url) else {
            setStatus("Quit \(source.displayName) before copying it.", level: .warning)
            return
        }
        guard let destinationURL else {
            setStatus("Choose where to save the patched copy.", level: .warning)
            return
        }
        if let validationMessage = destinationValidationMessage(for: source) {
            setStatus(validationMessage, level: .warning)
            return
        }
        guard let scriptURL = Bundle.main.url(forResource: "patch-model-slider", withExtension: "sh") else {
            setStatus("The patch script is missing from this app. Rebuild the launcher.", level: .error)
            return
        }

        let stagingURL = makeStagingURL(for: destinationURL)
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            setStatus("Could not reserve a temporary location for the patched copy. Try again.", level: .error)
            return
        }

        isRunning = true
        activityLabel = "Copying…"
        lastPatchedCopyURL = nil
        recoverableStagingURL = nil
        let replacingExistingCopy = willReplaceDestination
        output = """
        === Creating ChatGPT (Patched).app ===
        Source (unchanged): \(source.url.path)
        Final output:      \(destinationURL.path)
        Selected features: \(selectedFeatures.sorted { $0.title < $1.title }.map(\.title).joined(separator: ", "))

        Copying the source app to a private staging location…
        """
        if replacingExistingCopy {
            appendOutput("An existing output will be replaced only after this copy passes verification.\n")
        }
        setStatus("Copying \(source.displayName)…", level: .working)

        startCopyProcess(
            sourceURL: source.url,
            stagingURL: stagingURL,
            destinationURL: destinationURL,
            scriptURL: scriptURL
        )
    }

    func revealOutputInFinder() {
        guard let outputToRevealURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputToRevealURL])
    }

    func toggleFeature(_ feature: PatchFeature) {
        guard !isRunning else { return }
        if selectedFeatures.contains(feature) {
            selectedFeatures.remove(feature)
        } else {
            selectedFeatures.insert(feature)
        }
        lastPatchedCopyURL = nil
        updateStatus()
    }

    func updateStatus() {
        guard !isRunning else { return }
        guard let source = selectedTarget else {
            setStatus("No ChatGPT app was found automatically. Choose a source app.", level: .warning)
            refreshIdleConsole()
            return
        }
        if !source.isUsableSource {
            setStatus(source.sourceValidationMessage, level: .warning)
        } else if selectedFeatures.isEmpty {
            setStatus("Select at least one feature to include in the patched copy.", level: .warning)
        } else if isAppRunning(at: source.url) {
            setStatus("\(source.displayName) is running. Quit it before creating a copy.", level: .warning)
        } else if let destinationValidationMessage = destinationValidationMessage(for: source) {
            setStatus(destinationValidationMessage, level: .warning)
        } else if source.isAlreadyPatched {
            setStatus("This source is already patched. Prefer the original installed ChatGPT app as the clean source.", level: .warning)
        } else if willReplaceDestination {
            setStatus("Ready to replace the existing patched copy after verification. The source app will remain unchanged.", level: .warning)
        } else {
            setStatus("Ready to create a patched copy. The source app will remain unchanged.", level: .ready)
        }
        refreshIdleConsole()
    }

    private func refreshIdleConsole() {
        guard !isRunning, lastPatchedCopyURL == nil else { return }
        output = idleConsoleText()
    }

    private func idleConsoleText() -> String {
        let sourceLine: String
        if let source = selectedTarget {
            sourceLine = "\(source.displayName) · \(source.url.path)"
        } else {
            sourceLine = "(not selected)"
        }

        let outputLine: String
        if let destinationURL {
            outputLine = "\(destinationURL.deletingPathExtension().lastPathComponent) · \(destinationURL.deletingLastPathComponent().path)"
        } else {
            outputLine = "(not selected)"
        }

        let featuresBlock: String
        if selectedFeatures.isEmpty {
            featuresBlock = "  (none selected — choose at least one)"
        } else {
            featuresBlock = selectedFeatures
                .sorted { $0.title < $1.title }
                .map(idleFeatureLine)
                .joined(separator: "\n")
        }

        return """
        Ready to build ChatGPT (Patched).app

        Source (unchanged):  \(sourceLine)
        Output:              \(outputLine)

        Features:
        \(featuresBlock)

        Default picker point: 5.6 Sol · medium
        Quit ChatGPT before patching or launching the patched copy.
        Re-run the patcher after each ChatGPT app update.
        """
    }

    private func idleFeatureLine(for feature: PatchFeature) -> String {
        switch feature {
        case .customModelSlider:
            return "  • Custom Model Slider — default track: 5.6 Luna + 5.6 Sol (Terra/OpenCode in Settings)"
        case .hideProfileMenuItems:
            return "  • Hide Profile Menu Items — remove Show pet and Invite a friend from the account menu"
        case .openCodeGoProvider:
            return "  • OpenCode Go Provider — 20 third-party models (separate per-thread provider)"
        }
    }

    private func startCopyProcess(
        sourceURL: URL,
        stagingURL: URL,
        destinationURL: URL,
        scriptURL: URL
    ) {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // Keep the macOS metadata needed by an app bundle. Quarantine is
        // cleared by the patch worker after the copy has been verified.
        process.arguments = ["--rsrc", "--acl", sourceURL.path, stagingURL.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            DispatchQueue.main.async {
                self?.appendOutput(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let remainingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingText = String(data: remainingData, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                guard let self else { return }
                self.appendOutput(remainingText)
                self.activeProcess = nil

                guard process.terminationStatus == 0 else {
                    self.removeStagingCopy(at: stagingURL)
                    self.isRunning = false
                    self.setStatus("Could not duplicate the source app. The source was not changed.", level: .error)
                    self.appendOutput("ERROR: ditto exited with code \(process.terminationStatus).\n")
                    return
                }

                let stagingTarget = self.makeTarget(stagingURL)
                guard stagingTarget.isPatchableCopy else {
                    self.removeStagingCopy(at: stagingURL)
                    self.isRunning = false
                    self.setStatus("The copied app is not writable. Choose a different output location.", level: .error)
                    self.appendOutput("ERROR: The staged copy cannot be patched.\n")
                    return
                }

                self.appendOutput("Copy complete. Patching the staged copy…\n\n")
                self.startPatchProcess(
                    scriptURL: scriptURL,
                    stagingURL: stagingURL,
                    destinationURL: destinationURL
                )
            }
        }

        do {
            activeProcess = process
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            activeProcess = nil
            removeStagingCopy(at: stagingURL)
            isRunning = false
            setStatus("Could not start the copy operation. The source was not changed.", level: .error)
            appendOutput("ERROR: \(error.localizedDescription)\n")
        }
    }

    private func startPatchProcess(scriptURL: URL, stagingURL: URL, destinationURL: URL) {
        activityLabel = "Patching copy…"
        setStatus("Patching the duplicate…", level: .working)

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, stagingURL.path]
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.environment = environmentWithDeveloperToolPaths()

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            DispatchQueue.main.async {
                self?.appendOutput(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let remainingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let remainingText = String(data: remainingData, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                guard let self else { return }
                self.appendOutput(remainingText)
                self.activeProcess = nil

                if process.terminationStatus == 0 {
                    self.publishStagedCopy(from: stagingURL, to: destinationURL)
                } else {
                    self.removeStagingCopy(at: stagingURL)
                    self.isRunning = false
                    self.setStatus("Patch failed (exit code \(process.terminationStatus)). The source was not changed.", level: .error)
                    self.appendOutput("ERROR: The staged copy was removed.\n")
                }
            }
        }

        do {
            activeProcess = process
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            activeProcess = nil
            removeStagingCopy(at: stagingURL)
            isRunning = false
            setStatus("Could not start the patch script. The source was not changed.", level: .error)
            appendOutput("ERROR: \(error.localizedDescription)\n")
        }
    }

    private func publishStagedCopy(from stagingURL: URL, to destinationURL: URL) {
        do {
            let replacingExistingCopy = FileManager.default.fileExists(atPath: destinationURL.path)
            if replacingExistingCopy {
                // The existing output stays intact until the staged app has
                // fully patched and verified. This replacement happens inside
                // the same folder, so it is an atomic publish operation.
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                // FileManager move uses direct rename semantics here. Since
                // staging and final output share a parent directory, publishing
                // is atomic and fails safely if another app appears first.
                try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
            }
            isRunning = false
            lastPatchedCopyURL = destinationURL
            setStatus(
                replacingExistingCopy
                    ? "Patched copy replaced. The source app was not changed."
                    : "Patched copy created. The source app was not changed.",
                level: .success
            )
            appendOutput("\nPublished patched copy: \(destinationURL.path)\n")
        } catch {
            isRunning = false
            recoverableStagingURL = stagingURL
            setStatus("The copy was patched but could not be published. The source was not changed.", level: .error)
            appendOutput("ERROR: Could not publish the copy: \(error.localizedDescription)\n")
            appendOutput("The staged copy was kept at: \(stagingURL.path)\n")
        }
    }

    private func removeStagingCopy(at stagingURL: URL) {
        guard FileManager.default.fileExists(atPath: stagingURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: stagingURL)
        } catch {
            recoverableStagingURL = stagingURL
            appendOutput("WARNING: Could not remove staging copy: \(error.localizedDescription)\n")
        }
    }

    private func destinationValidationMessage(for source: AppTarget) -> String? {
        guard let destinationURL else {
            return "Choose where to save the patched copy."
        }

        let sourcePath = resolvedPath(for: source.url)
        let destinationPath = resolvedPath(for: destinationURL)
        if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
            return "The patched copy must be outside the source app bundle."
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return "The output path is occupied by a file. Choose a different name."
            }
            guard destinationURL.pathExtension.lowercased() == "app" else {
                return "The existing output must be an app bundle. Choose a different name."
            }
            if isAppRunning(at: destinationURL) {
                return "Quit the existing patched copy before replacing it."
            }
        }

        let parentDirectory = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "The selected output folder does not exist."
        }
        guard FileManager.default.isWritableFile(atPath: parentDirectory.path) else {
            return "The selected output folder is not writable."
        }

        return nil
    }

    private func suggestedDestination() -> URL {
        let directory = preferredDestinationDirectory()
        // Keep the default output stable so rerunning the patcher replaces the
        // latest patched copy instead of creating a new dated bundle each day.
        return directory
            .appendingPathComponent("ChatGPT (Patched)")
            .appendingPathExtension("app")
    }

    private func preferredDestinationDirectory() -> URL {
        let manager = FileManager.default
        if let savedPath = UserDefaults.standard.string(forKey: savedDestinationDirectoryPathKey) {
            let savedURL = URL(fileURLWithPath: savedPath)
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: savedURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue,
               manager.isWritableFile(atPath: savedURL.path) {
                return savedURL
            }
        }

        let userApplications = URL(fileURLWithPath: ("~/Applications" as NSString).expandingTildeInPath)
        if manager.fileExists(atPath: userApplications.path), manager.isWritableFile(atPath: userApplications.path) {
            return userApplications
        }

        return manager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Desktop" as NSString).expandingTildeInPath)
    }

    private func makeStagingURL(for destinationURL: URL) -> URL {
        let stem = destinationURL.deletingPathExtension().lastPathComponent
        return destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(stem).patching-\(UUID().uuidString)")
            .appendingPathExtension("app")
    }

    private func normalizedAppURL(_ url: URL) -> URL {
        guard url.pathExtension.lowercased() != "app" else { return url }
        return url.appendingPathExtension("app")
    }

    private func resolvedPath(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func standardCandidatePaths() -> [String] {
        let appBundle = Bundle.main.bundleURL
        let projectRootCandidate = appBundle
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ChatGPT-Hello.app")
            .path

        return [
            projectRootCandidate,
            "/Applications/Codex.app",
            "/Applications/ChatGPT.app",
            "~/Applications/Codex.app",
            "~/Applications/ChatGPT.app"
        ].map { ($0 as NSString).expandingTildeInPath }
    }

    private func makeTarget(_ url: URL) -> AppTarget {
        let bundleURL = url.standardizedFileURL
        let bundle = Bundle(url: bundleURL)
        let info = bundle?.infoDictionary
        let displayName = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let version = (info?["CFBundleShortVersionString"] as? String)
            ?? (info?["CFBundleVersion"] as? String)
        let asarURL = bundleURL.appendingPathComponent("Contents/Resources/app.asar")
        let resourcesURL = asarURL.deletingLastPathComponent()

        return AppTarget(
            url: bundleURL,
            displayName: displayName,
            bundleIdentifier: bundle?.bundleIdentifier,
            version: version,
            hasAsar: FileManager.default.fileExists(atPath: asarURL.path),
            isReadable: FileManager.default.isReadableFile(atPath: asarURL.path),
            isWritable: FileManager.default.isWritableFile(atPath: asarURL.path)
                && FileManager.default.isWritableFile(atPath: resourcesURL.path),
            isAlreadyPatched: FileManager.default.fileExists(
                atPath: asarURL.appendingPathExtension("original-backup").path
            )
        )
    }

    private func addOrUpdateTarget(_ target: AppTarget) {
        targets.removeAll { $0.id == target.id }
        targets.append(target)
        targets.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    private func isAppRunning(at url: URL) -> Bool {
        let selectedPath = resolvedPath(for: url)
        return NSWorkspace.shared.runningApplications.contains { application in
            guard let applicationURL = application.bundleURL else { return false }
            return resolvedPath(for: applicationURL) == selectedPath
        }
    }

    private func setStatus(_ message: String, level: StatusLevel) {
        status = message
        statusLevel = level
    }

    private func appendOutput(_ text: String) {
        guard !text.isEmpty else { return }
        output += text
    }

    private func environmentWithDeveloperToolPaths() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let defaultPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(defaultPath)"
        environment["PATCHER_SKIP_BACKUP"] = "1"
        environment["PATCHER_FEATURES"] = selectedFeatures.map(\.rawValue).sorted().joined(separator: ",")
        return environment
    }
}

private struct ContentView: View {
    @EnvironmentObject private var patcher: PatcherViewModel
    @State private var showingPatchConfirmation = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                header
                workflowRail

                HStack(alignment: .top, spacing: 12) {
                    sourceSection
                    destinationSection
                }

                featuresSection
                actionSection
                logSection
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(patcher.$selectedTarget) { _ in
            patcher.updateStatus()
        }
        .confirmationDialog(
            patcher.confirmationTitle,
            isPresented: $showingPatchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Create patched copy") {
                patcher.createPatchedCopy()
            }
        } message: {
            Text(patcher.confirmationMessage)
        }
    }

    private var sourceSection: some View {
        PatcherCard {
            VStack(alignment: .leading, spacing: 9) {
                SectionEyebrow(number: "01", title: "Source", symbol: "shippingbox")

                HStack(spacing: 10) {
                    AppGlyph(symbol: "app.dashed")

                    VStack(alignment: .leading, spacing: 3) {
                        Text(patcher.selectedTarget?.displayName ?? "No source selected")
                            .font(.system(size: 13, weight: .semibold))
                        Text(patcher.selectedTarget?.version.map { "Version \($0)" } ?? "Original application")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Menu {
                        ForEach(patcher.targets) { target in
                            Button(target.displayNameWithPath) {
                                patcher.selectSource(target)
                            }
                        }
                        Divider()
                        Button("Browse…") {
                            patcher.chooseAnotherApp()
                        }
                        Button("Rescan") {
                            patcher.refreshTargets()
                            patcher.updateStatus()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(patcher.isRunning)
                }

                PathWell(
                    path: patcher.selectedTarget?.url.path ?? "Choose the original ChatGPT app to copy",
                    symbol: "internaldrive"
                )

                HStack(spacing: 7) {
                    InfoChip(
                        title: patcher.selectedTarget?.isAlreadyPatched == true ? "Previously patched" : "Original stays untouched",
                        symbol: patcher.selectedTarget?.isAlreadyPatched == true ? "exclamationmark.triangle.fill" : "lock.shield.fill",
                        tint: patcher.selectedTarget?.isAlreadyPatched == true ? .orange : .green
                    )
                    Spacer(minLength: 0)
                    Button("Change…") { patcher.chooseAnotherApp() }
                        .buttonStyle(.link)
                        .disabled(patcher.isRunning)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var destinationSection: some View {
        PatcherCard {
            VStack(alignment: .leading, spacing: 9) {
                SectionEyebrow(number: "02", title: "Destination", symbol: "arrow.down.app")

                HStack(spacing: 10) {
                    AppGlyph(symbol: "doc.badge.gearshape")

                    VStack(alignment: .leading, spacing: 3) {
                        Text(patcher.destinationURL?.deletingPathExtension().lastPathComponent ?? "No output selected")
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("Verified patched copy")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if patcher.outputToRevealURL != nil {
                        Button {
                            patcher.revealOutputInFinder()
                        } label: {
                            Image(systemName: "finder")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }

                PathWell(
                    path: patcher.destinationURL?.path ?? "Choose where the patched copy should be saved",
                    symbol: "folder.fill"
                )

                HStack(spacing: 7) {
                    InfoChip(
                        title: patcher.willReplaceDestination ? "Replaces verified copy" : "Safe staged output",
                        symbol: patcher.willReplaceDestination ? "arrow.triangle.2.circlepath" : "checkmark.shield.fill",
                        tint: patcher.willReplaceDestination ? .orange : .blue
                    )
                    Spacer(minLength: 0)
                    Button("Choose…") { patcher.chooseDestination() }
                        .buttonStyle(.link)
                        .disabled(patcher.selectedTarget == nil || patcher.isRunning)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var actionSection: some View {
        HStack(spacing: 11) {
            if patcher.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18)
            } else {
                Image(systemName: patcher.statusLevel.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(patcher.statusLevel.tint)
                    .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(patcher.isRunning ? patcher.activityLabel : patcher.statusLevel.heading)
                    .font(.system(size: 13, weight: .semibold))
                Text(patcher.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            Button {
                showingPatchConfirmation = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "hammer")
                    Text("Build patched copy")
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 3)
                .frame(minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!patcher.canCreatePatchedCopy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.primary.opacity(0.1), lineWidth: 1)
        }
    }

    private var featuresSection: some View {
        PatcherCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    SectionEyebrow(number: "03", title: "Features", symbol: "puzzlepiece.extension")
                    Text("\(patcher.selectedFeatures.count) selected")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                ForEach(PatchFeature.allCases) { feature in
                    FeatureSelectionRow(
                        feature: feature,
                        isSelected: patcher.selectedFeatures.contains(feature),
                        isDisabled: patcher.isRunning
                    ) {
                        patcher.toggleFeature(feature)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 9) {
                    Text("ChatGPT Patcher")
                    .font(.system(size: 19, weight: .semibold))
                }
                Text("Build a customized, verified copy while your original app stays pristine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 10) {
                updateControl

                Label("On-device", systemImage: "lock")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        switch patcher.updateState {
        case .checking:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking…")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        case .upToDate:
            Button("Check for updates") {
                patcher.checkForUpdates()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .help("Installed version \(patcher.installedVersion)")
        case let .available(version):
            Button {
                patcher.installAvailableUpdate()
            } label: {
                Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        case let .downloading(version):
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Downloading \(version)…")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        case let .failed(message):
            Button("Retry update check") {
                patcher.checkForUpdates()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .help(message)
        }
    }

    private var workflowRail: some View {
        HStack(spacing: 0) {
            WorkflowStep(number: "1", title: "Select source", isActive: patcher.selectedTarget != nil)
            WorkflowConnector(isActive: patcher.selectedTarget != nil)
            WorkflowStep(number: "2", title: "Choose output", isActive: patcher.destinationURL != nil)
            WorkflowConnector(isActive: !patcher.selectedFeatures.isEmpty)
            WorkflowStep(number: "3", title: "Select features", isActive: !patcher.selectedFeatures.isEmpty)
            WorkflowConnector(isActive: patcher.canCreatePatchedCopy || patcher.isRunning || patcher.lastPatchedCopyURL != nil)
            WorkflowStep(
                number: "4",
                title: patcher.lastPatchedCopyURL == nil ? "Patch & verify" : "Complete",
                isActive: patcher.canCreatePatchedCopy || patcher.isRunning || patcher.lastPatchedCopyURL != nil
            )
        }
        .padding(.horizontal, 2)
    }

    private var logSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                Text("Patch log")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if patcher.isRunning {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Running")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    } else {
                    Text("Output")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Color.primary.opacity(0.025))

            Divider().opacity(0.25)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(patcher.output)
                            .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color(nsColor: .textColor).opacity(0.82))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Color.clear.frame(height: 1).id("patch-log-bottom")
                    }
                    .padding(12)
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo("patch-log-bottom", anchor: .bottom) }
                }
                .onReceive(patcher.$output) { _ in
                    DispatchQueue.main.async { proxy.scrollTo("patch-log-bottom", anchor: .bottom) }
                }
            }
            .frame(minHeight: 96, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.primary.opacity(0.1), lineWidth: 1)
        }
    }
}

private struct PatcherCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(11)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.primary.opacity(0.1), lineWidth: 1)
            }
    }
}

private struct SectionEyebrow: View {
    let number: String
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 7) {
            Text(number)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 17, alignment: .leading)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct AppGlyph: View {
    let symbol: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.055))
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .frame(width: 30, height: 30)
    }
}

private struct FeatureSelectionRow: View {
    let feature: PatchFeature
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(feature.summary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: feature.symbolName)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.primary.opacity(0.045) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(isSelected ? 0.1 : 0.06))
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(feature.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Toggles this feature in the patched copy")
    }
}

private struct PathWell: View {
    let path: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct InfoChip: View {
    let title: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct WorkflowStep: View {
    let number: String
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.12))
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text(number)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 10.5, weight: isActive ? .medium : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(width: 116, height: 22, alignment: .leading)
    }
}

private struct WorkflowConnector: View {
    let isActive: Bool

    var body: some View {
        Rectangle()
            .fill(isActive ? Color.primary.opacity(0.28) : Color.secondary.opacity(0.12))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
    }
}

private extension StatusLevel {
    var heading: String {
        switch self {
        case .neutral: "Setup required"
        case .ready: "Ready to build"
        case .working: "Build in progress"
        case .warning: "Attention needed"
        case .error: "Build interrupted"
        case .success: "Patch complete"
        }
    }
}

private extension AppTarget {
    var displayNameWithPath: String {
        "\(displayName) — \(url.path)"
    }
}
