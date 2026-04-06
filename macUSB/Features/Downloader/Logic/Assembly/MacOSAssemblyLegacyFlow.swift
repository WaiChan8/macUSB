import Foundation

extension MontereyDownloadFlowModel {
    private struct LegacyAssemblyFiles {
        let installAssistantAuto: URL
        let recoveryHDMetaDmg: URL
        let installESDDmg: URL
    }

    func runLegacyAssemblyWithoutRoot(
        manifest: DownloadManifest,
        entry: MacOSInstallerEntry
    ) async throws -> URL {
        guard let sessionRootURL = activeSessionRootURL else {
            throw DownloadFailureReason.assemblyFailed("Brak katalogu sesji dla legacy assembly")
        }

        let files = try resolveLegacyAssemblyFiles(from: manifest)
        let workspaceURL = sessionRootURL.appendingPathComponent("legacy_assembly", isDirectory: true)
        let expandedURL = workspaceURL.appendingPathComponent("InstallAssistant", isDirectory: true)
        let mountURL = workspaceURL.appendingPathComponent("RecoveryHDMount_\(UUID().uuidString)", isDirectory: true)

        AppLogging.info(
            "Legacy assembly: start entry=\(entry.name) \(entry.version), workspace=\(workspaceURL.path)",
            category: "Downloader"
        )
        AppLogging.info(
            "Legacy assembly: inputs resolved InstallAssistantAuto=\(files.installAssistantAuto.lastPathComponent), RecoveryHDMetaDmg=\(files.recoveryHDMetaDmg.lastPathComponent), InstallESDDmg=\(files.installESDDmg.lastPathComponent)",
            category: "Downloader"
        )

        do {
            if FileManager.default.fileExists(atPath: workspaceURL.path) {
                try FileManager.default.removeItem(at: workspaceURL)
            }
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        } catch {
            throw DownloadFailureReason.assemblyFailed("Nie udalo sie przygotowac katalogu roboczego legacy: \(error.localizedDescription)")
        }

        var recoveryMounted = false
        defer {
            if recoveryMounted {
                AppLogging.info(
                    "Legacy assembly: cleanup detach recovery mount=\(mountURL.path)",
                    category: "Downloader"
                )
                _ = try? runProcessAndCaptureOutput(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["detach", mountURL.path, "-force"]
                )
            }
            try? FileManager.default.removeItem(at: mountURL)
        }

        _ = try await runCommandWithBuildProgress(
            executable: "/usr/sbin/pkgutil",
            arguments: ["--expand-full", files.installAssistantAuto.path, expandedURL.path],
            statusText: "Rozpakowuję pakiet InstallAssistantAuto.pkg...",
            progressStart: 0.08,
            progressEnd: 0.26,
            stepName: "pkgutil expand"
        )

        let payloadURL = expandedURL.appendingPathComponent("Payload", isDirectory: true)
        let appURL = try locateLegacyInstallerApp(in: payloadURL)
        AppLogging.info(
            "Legacy assembly: detected app bundle path=\(appURL.path)",
            category: "Downloader"
        )
        let sharedSupportURL = appURL.appendingPathComponent("Contents/SharedSupport", isDirectory: true)

        try await runLegacyFileStepWithProgress(
            statusText: "Przygotowuję pliki SharedSupport...",
            progressStart: 0.28,
            progressEnd: 0.38,
            stepName: "prepare SharedSupport"
        ) {
            try FileManager.default.createDirectory(at: sharedSupportURL, withIntermediateDirectories: true)
            let installESDDestinationURL = sharedSupportURL.appendingPathComponent("InstallESD.dmg")
            try self.copyItemReplacing(sourceURL: files.installESDDmg, destinationURL: installESDDestinationURL)
        }

        _ = try await runCommandWithBuildProgress(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-readonly", "-nobrowse", files.recoveryHDMetaDmg.path, "-mountpoint", mountURL.path],
            statusText: "Montuję RecoveryHDMetaDmg.pkg...",
            progressStart: 0.40,
            progressEnd: 0.52,
            stepName: "attach recovery image"
        )
        recoveryMounted = true

        try await runLegacyFileStepWithProgress(
            statusText: "Kopiuję zasoby RecoveryHD do SharedSupport...",
            progressStart: 0.54,
            progressEnd: 0.72,
            stepName: "copy RecoveryHD assets"
        ) {
            let mountedItems = try FileManager.default.contentsOfDirectory(
                at: mountURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for sourceItem in mountedItems {
                let destinationItem = sharedSupportURL.appendingPathComponent(sourceItem.lastPathComponent, isDirectory: false)
                try self.copyItemReplacing(sourceURL: sourceItem, destinationURL: destinationItem)
            }
        }

        buildStatusText = "Kończę montowanie RecoveryHD..."
        buildProgress = 0.74
        AppLogging.info(
            "Legacy assembly: detach recovery mount=\(mountURL.path)",
            category: "Downloader"
        )
        _ = try? runProcessAndCaptureOutput(
            executable: "/usr/bin/hdiutil",
            arguments: ["detach", mountURL.path, "-force"]
        )
        recoveryMounted = false

        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let preferredName = expectedInstallerAppName(for: entry)
        let destinationURL = uniqueCollisionSafeURL(
            in: applicationsURL,
            preferredFileName: preferredName
        )
        if destinationURL.lastPathComponent != preferredName {
            AppLogging.info(
                "Legacy assembly: wykryto kolizje nazwy w /Applications, używam \(destinationURL.lastPathComponent)",
                category: "Downloader"
            )
        }
        try await runLegacyFileStepWithProgress(
            statusText: "Przenoszę gotowy instalator do /Applications...",
            progressStart: 0.80,
            progressEnd: 0.96,
            stepName: "copy installer to /Applications"
        ) {
            try self.copyItemReplacing(sourceURL: appURL, destinationURL: destinationURL)
        }

        AppLogging.info(
            "Legacy assembly: installer ready path=\(destinationURL.path)",
            category: "Downloader"
        )
        return destinationURL
    }

    private func locateLegacyInstallerApp(in payloadURL: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(
            at: payloadURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let installerApp = entries.first(where: { candidate in
            candidate.pathExtension.lowercased() == "app"
                && candidate.lastPathComponent.lowercased().hasPrefix("install ")
        }) else {
            throw DownloadFailureReason.assemblyFailed("Nie znaleziono aplikacji Install macOS .app po rozpakowaniu InstallAssistantAuto.pkg")
        }
        return installerApp
    }

    private func copyItemReplacing(sourceURL: URL, destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func resolveLegacyAssemblyFiles(from manifest: DownloadManifest) throws -> LegacyAssemblyFiles {
        let requiredPackageIDs: [String: String] = [
            "com.apple.pkg.InstallAssistantAuto": "InstallAssistantAuto.pkg",
            "com.apple.pkg.RecoveryHDMetaDmg": "RecoveryHDMetaDmg.pkg",
            "com.apple.pkg.InstallESDDmg": "InstallESDDmg.pkg"
        ]

        var resolvedByID: [String: URL] = [:]
        for item in manifest.items {
            guard let packageID = item.packageIdentifier?.lowercased(),
                  requiredPackageIDs.keys.contains(where: { $0.lowercased() == packageID })
            else {
                continue
            }
            if let localURL = downloadedFileURLsByItemID[item.id] {
                resolvedByID[packageID] = localURL
            }
        }

        func resolveRequiredFile(_ packageIdentifier: String) -> URL? {
            if let byID = resolvedByID[packageIdentifier.lowercased()],
               FileManager.default.fileExists(atPath: byID.path) {
                return byID
            }
            guard let fallbackName = requiredPackageIDs[packageIdentifier] else { return nil }
            if let fallbackItem = manifest.items.first(where: { item in
                item.name.caseInsensitiveCompare(fallbackName) == .orderedSame
                    || item.url.lastPathComponent.caseInsensitiveCompare(fallbackName) == .orderedSame
            }), let fallbackURL = downloadedFileURLsByItemID[fallbackItem.id],
               FileManager.default.fileExists(atPath: fallbackURL.path) {
                return fallbackURL
            }
            return nil
        }

        guard let installAssistantAuto = resolveRequiredFile("com.apple.pkg.InstallAssistantAuto") else {
            throw DownloadFailureReason.assemblyFailed("Brak wymaganego pliku InstallAssistantAuto.pkg dla legacy assembly")
        }
        guard let recoveryHDMetaDmg = resolveRequiredFile("com.apple.pkg.RecoveryHDMetaDmg") else {
            throw DownloadFailureReason.assemblyFailed("Brak wymaganego pliku RecoveryHDMetaDmg.pkg dla legacy assembly")
        }
        guard let installESDDmg = resolveRequiredFile("com.apple.pkg.InstallESDDmg") else {
            throw DownloadFailureReason.assemblyFailed("Brak wymaganego pliku InstallESDDmg.pkg dla legacy assembly")
        }

        return LegacyAssemblyFiles(
            installAssistantAuto: installAssistantAuto,
            recoveryHDMetaDmg: recoveryHDMetaDmg,
            installESDDmg: installESDDmg
        )
    }
}
