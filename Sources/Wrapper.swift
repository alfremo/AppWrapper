import AppKit

/// A wrapper is an APFS clone of a source app with its own bundle id, name and LSEnvironment,
/// ad-hoc re-signed. Its config lives in its own Info.plist, so the list is just a scan of ~/Applications.
struct Wrapper: Identifiable, Hashable {
    var id = UUID().uuidString.lowercased()
    var name = ""
    var source: URL?
    var isolated = true
    var envText = ""
    var badge = ""
    var badgeColor = NSColor.systemRed
    var url: URL?  // nil until built

    static let appsDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")
    static let dataRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/AppWrapper")

    var homeDir: URL { Self.dataRoot.appending(path: id) }

    // MARK: env text <-> dictionary

    static func parseEnv(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { env[key] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces) }
        }
        return env
    }

    static func formatEnv(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0]!)" }.joined(separator: "\n")
    }

    // MARK: listing

    static func all() -> [Wrapper] {
        let apps = (try? FileManager.default.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil)) ?? []
        return apps.compactMap(load).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func load(_ url: URL) -> Wrapper? {
        guard url.pathExtension == "app",
              let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")),
              let id = info["AppWrapperID"] as? String else { return nil }
        return Wrapper(
            id: id,
            name: url.deletingPathExtension().lastPathComponent,
            source: (info["AppWrapperSource"] as? String).map { URL(fileURLWithPath: $0) },
            isolated: info["AppWrapperIsolated"] as? Bool ?? false,
            envText: formatEnv(info["AppWrapperEnv"] as? [String: String] ?? [:]),
            badge: info["AppWrapperBadge"] as? String ?? "",
            badgeColor: (info["AppWrapperBadgeColor"] as? String).flatMap(NSColor.init(hex:)) ?? .systemRed,
            url: url)
    }

    // MARK: building

    struct BuildError: LocalizedError { var errorDescription: String? }

    /// Creates or rebuilds the wrapper. Blocking; call off the main thread.
    func build() throws -> URL {
        let fm = FileManager.default
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let source = source?.resolvingSymlinksInPath() else { throw BuildError(errorDescription: "Pick a source app.") }
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw BuildError(errorDescription: "Enter a valid name.")
        }
        let dest = Self.appsDir.appending(path: "\(name).app")
        if fm.fileExists(atPath: dest.path), Self.load(dest)?.id != id {
            throw BuildError(errorDescription: "\(dest.path) already exists and isn't this wrapper.")
        }
        guard let srcInfo = NSDictionary(contentsOf: source.appending(path: "Contents/Info.plist")),
              let srcID = srcInfo["CFBundleIdentifier"] as? String else {
            throw BuildError(errorDescription: "\(source.lastPathComponent) isn't a valid app bundle.")
        }
        if srcInfo["AppWrapperID"] != nil {
            throw BuildError(errorDescription: "Pick the original app, not a wrapper.")
        }

        try fm.createDirectory(at: Self.appsDir, withIntermediateDirectories: true)
        let tmp = Self.appsDir.appending(path: ".\(id).building.app")
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }
        try fm.copyItem(at: source, to: tmp)  // clonefile on APFS: near-instant, no extra disk

        // Localized InfoPlist.strings would override our CFBundleDisplayName in Finder/Dock.
        if let lprojs = try? fm.contentsOfDirectory(at: tmp.appending(path: "Contents/Resources"), includingPropertiesForKeys: nil) {
            for lproj in lprojs where lproj.pathExtension == "lproj" {
                try? fm.removeItem(at: lproj.appending(path: "InfoPlist.strings"))
            }
        }

        var lsEnv = Self.parseEnv(envText)
        if isolated {
            try makeHome()
            lsEnv["HOME"] = homeDir.path
            lsEnv["CFFIXED_USER_HOME"] = homeDir.path  // what Foundation/NSHomeDirectory honours
        }

        let infoURL = tmp.appending(path: "Contents/Info.plist")
        let info = NSMutableDictionary(contentsOf: infoURL)!
        info["CFBundleIdentifier"] = "\(srcID).wrapper-\(id.prefix(8))"
        // CFBundleName stays: Electron derives its helper paths from it ("<CFBundleName> Helper.app")
        // and aborts at launch if they're missing. The display name is what Finder/Dock show.
        info["CFBundleDisplayName"] = name
        info["LSEnvironment"] = lsEnv
        info["SUEnableAutomaticChecks"] = false  // a Sparkle update would overwrite the clone with the stock app
        info["AppWrapperID"] = id
        info["AppWrapperSource"] = source.path
        info["AppWrapperIsolated"] = isolated
        info["AppWrapperEnv"] = Self.parseEnv(envText)
        info["AppWrapperBadge"] = badge
        info["AppWrapperBadgeColor"] = badgeColor.hex
        if let icon = renderIcon() {
            // Fresh name each build, or Icon Services keeps showing the previous icon.
            let iconName = "AppWrapperIcon-\(Int(Date().timeIntervalSince1970))"
            try Self.writeICNS(icon, to: tmp.appending(path: "Contents/Resources/\(iconName).icns"))
            info["CFBundleIconFile"] = iconName
            info.removeObject(forKey: "CFBundleIconName")  // asset-catalog icon would win over our .icns
        }
        try info.write(to: infoURL)

        try Self.run("/usr/bin/xattr", "-cr", tmp.path)
        // ponytail: signing drops entitlements/hardened runtime. Apps needing restricted
        // entitlements (iCloud, some App Store apps) may refuse to run; no fix short of a dev cert.
        try Self.run("/usr/bin/codesign", "--force", "--deep", "--sign", Self.signer(), tmp.path)

        // Remove old copy (this build, or the pre-rename one) then move the new one into place.
        if let old = url, fm.fileExists(atPath: old.path) { try fm.removeItem(at: old) }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        // Bump mtimes so Icon Services drops its cached icon for this path on re-register.
        for f in [dest, dest.appending(path: "Contents"), dest.appending(path: "Contents/Info.plist")] {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        }
        try? Self.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", dest.path)
        return dest
    }

    /// Private home per wrapper, with the user's real folders and keychain linked in.
    private func makeHome() throws {
        let fm = FileManager.default
        let realHome = fm.homeDirectoryForCurrentUser
        try fm.createDirectory(at: homeDir.appending(path: "Library"), withIntermediateDirectories: true)
        for sub in ["Desktop", "Documents", "Downloads", "Library/Keychains"] {
            let link = homeDir.appending(path: sub)
            if (try? link.checkResourceIsReachable()) != true, (try? fm.destinationOfSymbolicLink(atPath: link.path)) == nil {
                try fm.createSymbolicLink(at: link, withDestinationURL: realHome.appending(path: sub))
            }
        }
    }

    /// A user-created code-signing certificate with this name (Keychain Access > Certificate Assistant)
    /// gives copies a stable signature, so a keychain "Always Allow" survives rebuilds. Without it,
    /// copies are signed ad-hoc, whose identity changes on every build.
    static let signingIdentity = "AppWrapper Local Signing"

    static func signer() -> String {
        let ids = (try? run("/usr/bin/security", "find-identity", "-p", "codesigning")) ?? ""
        return ids.contains("\"\(signingIdentity)\"") ? signingIdentity : "-"
    }

    @discardableResult
    static func run(_ tool: String, _ args: String...) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe(), out = Pipe()
        p.standardError = err
        p.standardOutput = out
        try p.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()  // ponytail: sequential reads; fine for these tools' small output
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw BuildError(errorDescription: "\((tool as NSString).lastPathComponent) failed: \(String(decoding: data, as: UTF8.self))")
        }
        return String(decoding: stdout, as: UTF8.self)
    }
}
