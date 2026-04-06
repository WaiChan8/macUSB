import Foundation

extension MontereyDownloadFlowModel {
    func verifyInstallerBuildIfAvailable(
        of appURL: URL,
        expectedBuild: String,
        expectedVersion: String
    ) throws {
        let expected = expectedBuild.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty, expected.caseInsensitiveCompare("N/A") != .orderedSame else {
            AppLogging.info(
                "Brak oczekiwanego builda dla \(appURL.lastPathComponent) (wersja \(expectedVersion)); pomijam walidacje build.",
                category: "Downloader"
            )
            return
        }

        var discoveredBuilds = extractInstallerBuildCandidates(from: appURL)
        if discoveredBuilds.isEmpty, let legacyBuild = try extractLegacyBuildFromInstallESDIfAvailable(appURL: appURL) {
            discoveredBuilds = [legacyBuild]
            AppLogging.info(
                "Odczytano build legacy z InstallESD.dmg dla \(appURL.lastPathComponent): \(legacyBuild)",
                category: "Downloader"
            )
        }
        guard !discoveredBuilds.isEmpty else {
            AppLogging.info(
                "Nie udalo sie odczytac builda z \(appURL.lastPathComponent); pomijam walidacje build (oczekiwano \(expected)).",
                category: "Downloader"
            )
            return
        }

        if discoveredBuilds.contains(where: { $0.caseInsensitiveCompare(expected) == .orderedSame }) {
            return
        }

        if isKnownCompatibleBuildAlias(
            expectedBuild: expected,
            discoveredBuilds: discoveredBuilds,
            expectedVersion: expectedVersion
        ) {
            AppLogging.info(
                "Akceptuje kompatybilny alias builda dla \(appURL.lastPathComponent): expected=\(expected), actual=\(discoveredBuilds.joined(separator: ", ")), version=\(expectedVersion).",
                category: "Downloader"
            )
            return
        }

        let actual = discoveredBuilds.joined(separator: ", ")
        throw DownloadFailureReason.assemblyFailed(
            "Finalny instalator ma build \(actual), oczekiwano \(expected)"
        )
    }

    private func isKnownCompatibleBuildAlias(
        expectedBuild: String,
        discoveredBuilds: [String],
        expectedVersion: String
    ) -> Bool {
        let normalizedVersion = expectedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedVersion == "12.7.6" else { return false }

        let expectedCanonical = expectedBuild.uppercased()
        let discoveredCanonical = Set(discoveredBuilds.map { $0.uppercased() })
        let montereyAliasSet: Set<String> = ["21H1319", "21H1320"]

        guard montereyAliasSet.contains(expectedCanonical) else { return false }
        return !discoveredCanonical.intersection(montereyAliasSet).isEmpty
    }

    private func extractInstallerBuildCandidates(from appURL: URL) -> [String] {
        var values: [String] = []

        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            return []
        }

        let infoKeys = ["ProductBuildVersion", "BuildVersion"]
        for key in infoKeys {
            if let value = plist[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    values.append(trimmed)
                }
            }
        }

        let installInfoURL = appURL
            .appendingPathComponent("Contents/SharedSupport", isDirectory: true)
            .appendingPathComponent("InstallInfo.plist")
        if let installInfoData = try? Data(contentsOf: installInfoURL),
           let installInfo = try? PropertyListSerialization.propertyList(from: installInfoData, options: [], format: nil) as? [String: Any] {
            if let rootBuild = installInfo["Build"] as? String {
                let trimmed = rootBuild.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    values.append(trimmed)
                }
            }
            if let systemImageInfo = installInfo["System Image Info"] as? [String: Any] {
                if let imageBuild = systemImageInfo["build"] as? String {
                    let trimmed = imageBuild.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        values.append(trimmed)
                    }
                }
            }
        }

        let osBuildRegex = try? NSRegularExpression(pattern: #"^[0-9]{1,3}[A-Za-z][0-9]{1,6}[A-Za-z]?$"#)
        let filtered = values.filter { candidate in
            let range = NSRange(location: 0, length: candidate.utf16.count)
            return osBuildRegex?.firstMatch(in: candidate, options: [], range: range) != nil
        }

        var unique: [String] = []
        var seen = Set<String>()
        for value in filtered {
            let canonical = value.lowercased()
            if seen.insert(canonical).inserted {
                unique.append(value)
            }
        }
        return unique
    }

    private func extractLegacyBuildFromInstallESDIfAvailable(appURL: URL) throws -> String? {
        let installESDURL = appURL
            .appendingPathComponent("Contents/SharedSupport", isDirectory: true)
            .appendingPathComponent("InstallESD.dmg")
        guard FileManager.default.fileExists(atPath: installESDURL.path) else {
            return nil
        }

        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let esdMountURL = tempRoot.appendingPathComponent("macusb_esd_\(UUID().uuidString)", isDirectory: true)
        let baseMountURL = tempRoot.appendingPathComponent("macusb_base_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: esdMountURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: baseMountURL, withIntermediateDirectories: true)

        var esdMounted = false
        var baseMounted = false
        defer {
            if baseMounted {
                _ = try? runProcessAndCaptureOutput(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["detach", baseMountURL.path, "-force"]
                )
            }
            if esdMounted {
                _ = try? runProcessAndCaptureOutput(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["detach", esdMountURL.path, "-force"]
                )
            }
            try? FileManager.default.removeItem(at: baseMountURL)
            try? FileManager.default.removeItem(at: esdMountURL)
        }

        _ = try runProcessAndCaptureOutput(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-readonly", "-nobrowse", installESDURL.path, "-mountpoint", esdMountURL.path]
        )
        esdMounted = true

        let directSystemVersionURL = esdMountURL
            .appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
        if let build = readBuildFromSystemVersionPlist(at: directSystemVersionURL) {
            return build
        }

        let baseCandidates = [
            esdMountURL.appendingPathComponent("BaseSystem.dmg"),
            esdMountURL.appendingPathComponent("BaseSystem/BaseSystem.dmg")
        ]
        guard let baseSystemURL = baseCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }

        _ = try runProcessAndCaptureOutput(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-readonly", "-nobrowse", baseSystemURL.path, "-mountpoint", baseMountURL.path]
        )
        baseMounted = true

        let baseSystemVersionURL = baseMountURL
            .appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
        return readBuildFromSystemVersionPlist(at: baseSystemVersionURL)
    }

    private func readBuildFromSystemVersionPlist(at plistURL: URL) -> String? {
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let build = plist["ProductBuildVersion"] as? String
        else {
            return nil
        }

        let trimmed = build.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
