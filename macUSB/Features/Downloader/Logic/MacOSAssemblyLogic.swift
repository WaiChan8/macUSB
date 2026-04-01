import Foundation
import Darwin

extension MontereyDownloadPlaceholderFlowModel {
    func runInstallerBuild(
        manifest: DownloadManifest,
        entry: MacOSInstallerEntry
    ) async throws {
        currentStage = .buildingInstaller
        buildStatusText = "Przygotowuję budowanie instalatora..."
        buildProgress = 0

        guard let packageURL = locateInstallAssistantPackage(in: manifest) else {
            throw DownloadFailureReason.assemblyFailed("Nie znaleziono pobranego InstallAssistant.pkg")
        }
        guard let outputDirectory = activeSessionOutputURL else {
            throw DownloadFailureReason.assemblyFailed("Brak katalogu output sesji")
        }

        let request = DownloaderAssemblyRequestPayload(
            packagePath: packageURL.path,
            outputDirectoryPath: outputDirectory.path,
            expectedAppName: "Install macOS Monterey.app",
            requesterUID: getuid()
        )

        let result = try await startAssemblyWithHelper(request: request)

        guard result.success else {
            throw DownloadFailureReason.assemblyFailed(result.errorMessage ?? "Helper zwrocil blad assembly")
        }
        guard let outputAppPath = result.outputAppPath else {
            throw DownloadFailureReason.assemblyFailed("Helper nie zwrocil sciezki do instalatora .app")
        }

        let assembledAppURL = URL(fileURLWithPath: outputAppPath)
        guard FileManager.default.fileExists(atPath: assembledAppURL.path) else {
            throw DownloadFailureReason.assemblyFailed("Zbudowana aplikacja instalatora nie istnieje")
        }

        let desktopTargetURL = try moveFinalInstallerToDesktop(assembledAppURL)
        try validateFinalInstallerApp(at: desktopTargetURL, expectedVersion: entry.version)
        finalInstallerAppURL = desktopTargetURL
        buildStatusText = "Instalator zapisano w \(desktopTargetURL.path)"
        buildProgress = 1.0
        completedStages.insert(.buildingInstaller)

        AppLogging.info(
            "Zakonczono budowanie .app Monterey i przeniesiono wynik do \(desktopTargetURL.path).",
            category: "Downloader"
        )
    }

    private func locateInstallAssistantPackage(in manifest: DownloadManifest) -> URL? {
        let preferred = manifest.items.first { item in
            item.name.localizedCaseInsensitiveContains("InstallAssistant.pkg")
                || item.url.lastPathComponent.localizedCaseInsensitiveContains("InstallAssistant.pkg")
        }

        guard let preferred else { return nil }
        return downloadedFileURLsByItemID[preferred.id]
    }

    private func startAssemblyWithHelper(
        request: DownloaderAssemblyRequestPayload
    ) async throws -> DownloaderAssemblyResultPayload {
        try await withCheckedThrowingContinuation { continuation in
            var didFinish = false
            let finish: (Result<DownloaderAssemblyResultPayload, Error>) -> Void = { result in
                guard !didFinish else { return }
                didFinish = true
                switch result {
                case let .success(payload):
                    continuation.resume(returning: payload)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }

            PrivilegedOperationClient.shared.startDownloaderAssembly(
                request: request,
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.buildProgress = min(max(event.percent, 0), 1)
                        self?.buildStatusText = event.statusText
                        if let logLine = event.logLine, !logLine.isEmpty {
                            AppLogging.info(logLine, category: "Downloader")
                        }
                    }
                },
                onCompletion: { [weak self] result in
                    Task { @MainActor [weak self] in
                        self?.activeAssemblyWorkflowID = nil
                    }
                    finish(.success(result))
                },
                onStartError: { message in
                    finish(.failure(DownloadFailureReason.assemblyFailed(message)))
                },
                onStarted: { [weak self] workflowID in
                    Task { @MainActor [weak self] in
                        self?.activeAssemblyWorkflowID = workflowID
                    }
                }
            )
        }
    }

    private func moveFinalInstallerToDesktop(_ builtAppURL: URL) throws -> URL {
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
        let downloadsFolder = desktopURL.appendingPathComponent("macUSB Downloads", isDirectory: true)

        try FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true)

        let preferredName = builtAppURL.lastPathComponent
        let destinationURL = uniqueAppDestinationURL(
            preferredName: preferredName,
            in: downloadsFolder
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: builtAppURL, to: destinationURL)
        return destinationURL
    }

    private func uniqueAppDestinationURL(preferredName: String, in directory: URL) -> URL {
        let baseName = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension

        var candidate = directory.appendingPathComponent(preferredName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        var suffix = 2
        while true {
            let nextName = "\(baseName) (\(suffix)).\(ext)"
            candidate = directory.appendingPathComponent(nextName, isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    private func validateFinalInstallerApp(at appURL: URL, expectedVersion: String) throws {
        try verifyCodeSignature(of: appURL)
        try verifyAppVersion(of: appURL, expectedVersion: expectedVersion)
    }

    private func verifyCodeSignature(of appURL: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = output

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            throw DownloadFailureReason.assemblyFailed("Nie udalo sie uruchomic weryfikacji codesign: \(error.localizedDescription)")
        }

        guard task.terminationStatus == 0 else {
            let details = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DownloadFailureReason.assemblyFailed("Weryfikacja podpisu .app nie powiodla sie\(details.isEmpty ? "" : ": \(details)")")
        }
    }

    private func verifyAppVersion(of appURL: URL, expectedVersion: String) throws {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let bundleVersion = plist["CFBundleShortVersionString"] as? String
        else {
            throw DownloadFailureReason.assemblyFailed("Nie udalo sie odczytac wersji z finalnego instalatora .app")
        }

        let expectedMajor = expectedVersion.split(separator: ".").first.map(String.init) ?? expectedVersion
        let actualMajor = bundleVersion.split(separator: ".").first.map(String.init) ?? bundleVersion
        guard actualMajor == expectedMajor else {
            throw DownloadFailureReason.assemblyFailed(
                "Finalny instalator ma wersje \(bundleVersion), oczekiwano \(expectedVersion)"
            )
        }
    }
}
