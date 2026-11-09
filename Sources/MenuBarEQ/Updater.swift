import AppKit
import Combine
import Security

/// Checks Barbeat's GitHub releases for a newer version and, when you say so, installs it.
/// A download is only installed if it's signed with Barbeat's Developer ID, notarized by Apple, and is Barbeat.
/// (A Mac App Store build must leave this out: the App Store does its own updates.)
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, downloading, installing
        case failed(String)
    }

    @Published private(set) var state = State.idle
    /// Check once a day on its own (asked in the update dialog).
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: Key.automatic) } }

    struct Release {
        var version: String
        var notes: String
        var page: URL
        var download: URL
    }

    private static let feed = URL(string: "https://api.github.com/repos/IchiroA/Barbeat/releases/latest")!
    /// Only a build signed by the same Developer ID team as this copy, notarized by Apple, with Barbeat's bundle ID.
    /// (A copy without a Developer ID, like a local build, can't check downloads, so it never installs one.)
    private static var requirement: String? {
        guard let team = ownTeamID else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"com.ia.MenuBarEQ\" and notarized"
    }

    /// The Developer ID team that signed this copy of Barbeat.
    private static var ownTeamID: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private enum Key {
        static let automatic = "updates.automatic", lastCheck = "updates.lastCheck", skipped = "updates.skipped"
    }

    /// `--update-feed <url>` reads that instead of GitHub; `--update-test` checks right away, downloads and verifies
    /// a newer version, prints what happened and quits, never showing a dialog or installing anything.
    private let feedOverride = Updater.argument("--update-feed").flatMap(URL.init(string:))
    let testing = CommandLine.arguments.contains("--update-test")

    private init() {
        defaults.register(defaults: [Key.automatic: true])
        automatic = defaults.bool(forKey: Key.automatic)
    }

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Called at launch: a quiet check a little later, then about once a day.
    func start() {
        if testing {
            check(manual: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard automatic, state == .idle || isFailed else { return }
        let last = defaults.object(forKey: Key.lastCheck) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) > 20 * 3600 { check(manual: false) }
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    /// `manual`: from "Check for Updates…", so it also says when you're up to date or the check failed.
    func check(manual: Bool) {
        guard state == .idle || isFailed else { return }
        state = .checking
        var request = URLRequest(url: feedOverride ?? Self.feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { self?.handle(data: data, response: response, error: error, manual: manual) }
        }.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?, manual: Bool) {
        state = .idle
        defaults.set(Date(), forKey: Key.lastCheck)
        guard let data, error == nil, (response as? HTTPURLResponse)?.statusCode ?? 200 < 300,
              let release = Self.parse(data) else {
            let why = error?.localizedDescription ?? "GitHub didn't answer as expected."
            note("check failed: \(why)")
            if testing { finishTest() }
            if manual && !testing { tell("Couldn't check for updates", why) }
            return
        }
        let current = Self.currentVersion
        guard Self.isNewer(release.version, than: current) else {
            note("up to date: \(current) (latest \(release.version))")
            if testing { finishTest() }
            if manual && !testing { tell("You're up to date", "Barbeat \(current) is the latest version.") }
            return
        }
        note("Barbeat \(release.version) is available (this is \(current))")
        if testing {
            install(release)
            return
        }
        if !manual, defaults.string(forKey: Key.skipped) == release.version { return }
        offer(release, manual: manual)
    }

    // MARK: - Asking

    private func offer(_ release: Release, manual: Bool) {
        let alert = NSAlert()
        alert.messageText = "Barbeat \(release.version) is available"
        var notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 600 { notes = String(notes.prefix(600)) + "…" }
        alert.informativeText = "You have \(Self.currentVersion). Update now? Barbeat restarts by itself, and your lights are handed back first."
            + (notes.isEmpty ? "" : "\n\n" + notes)
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        if !manual { alert.addButton(withTitle: "Skip This Version") }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Check for updates automatically"
        alert.suppressionButton?.state = automatic ? .on : .off
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        automatic = alert.suppressionButton?.state == .on
        switch answer {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: defaults.set(release.version, forKey: Key.skipped)
        default: break
        }
    }

    // MARK: - Installing

    private func install(_ release: Release) {
        state = .downloading
        note("downloading \(release.download.absoluteString)")
        URLSession.shared.downloadTask(with: release.download) { [weak self] file, _, error in
            guard let self else { return }
            // The download is deleted when this returns, so unpack it here.
            let result = Result { () -> URL in
                guard let file, error == nil else { throw UpdateError(error?.localizedDescription ?? "The download failed.") }
                return try self.unpackAndVerify(file, expecting: release.version)
            }
            DispatchQueue.main.async { self.finishInstall(result, release: release) }
        }.resume()
    }

    /// Unzips the download next to the installed app (same disk, so the swap is a quick rename) and checks it.
    private func unpackAndVerify(_ zip: URL, expecting version: String) throws -> URL {
        let current = Bundle.main.bundleURL
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: current, create: true)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: work) } }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError("The download couldn't be unpacked.") }
        guard let app = Self.findApp(in: work) else { throw UpdateError("The download has no Barbeat app in it.") }

        guard let rule = Self.requirement else {
            throw UpdateError("This copy of Barbeat isn't signed with a Developer ID, so it can't check the download.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess else {
            throw UpdateError("The download's signature couldn't be read.")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError("The download isn't signed and notarized as Barbeat, so it wasn't installed.")
        }
        let downloaded = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard !Self.isNewer(version, than: downloaded) else {
            throw UpdateError("The download is version \(downloaded), not \(version).")
        }
        keep = true
        return app
    }

    private func finishInstall(_ result: Result<URL, Error>, release: Release) {
        switch result {
        case .failure(let error):
            let message = (error as? UpdateError)?.message ?? error.localizedDescription
            note("update failed: \(message)")
            state = .failed(message)
            if testing { return finishTest() }
            failed(message, page: release.page)
        case .success(let app):
            note("verified \(app.path)")
            if testing {
                note("test: would install it and restart (nothing changed)")
                return finishTest()
            }
            state = .installing
            do {
                _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: app)
            } catch {
                state = .failed(error.localizedDescription)
                failed("Barbeat couldn't replace itself: \(error.localizedDescription)", page: release.page)
                return
            }
            relaunch()
        }
    }

    /// Opens the new copy once this one has fully quit (quitting hands the lights back first).
    private func relaunch() {
        let wait = Process()
        wait.executableURL = URL(fileURLWithPath: "/bin/sh")
        wait.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundleURL.path]
        try? wait.run()
        NSApp.terminate(nil)
    }

    private func failed(_ message: String, page: URL) {
        let alert = NSAlert()
        alert.messageText = "The update didn't install"
        alert.informativeText = message + "\n\nYou can download it from the release page instead."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(page) }
        state = .idle
    }

    private func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Bits

    /// The latest release from GitHub's JSON: its version (from the tag, "v1.11" → "1.11") and the app's zip.
    static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]],
              let zip = assets.first(where: { (($0["name"] as? String) ?? "").hasPrefix("Barbeat") && (($0["name"] as? String) ?? "").hasSuffix(".zip") }),
              let download = (zip["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", page: page, download: download)
    }

    /// "1.11" is newer than "1.10" and "1.9" (compared number by number).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private static func findApp(in folder: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.pathExtension == "app" {
            if url.lastPathComponent == "Barbeat.app" { return url }
            walker.skipDescendants()
        }
        return nil
    }

    private func note(_ text: String) {
        if testing || CommandLine.arguments.contains("--verbose") { print("update: \(text)") }
    }

    private func finishTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    private static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
