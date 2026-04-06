import Foundation

extension MontereyDownloadFlowModel {
    func verifyTemporaryDiskCapacity(requiredBytes: Int64) throws {
        let probeURL = FileManager.default.temporaryDirectory
        let reserveBytes: Int64 = max(2_000_000_000, Int64(Double(requiredBytes) * 0.10))
        let minimumRequired = requiredBytes + reserveBytes

        let values = try probeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let availableBytes = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        guard availableBytes >= minimumRequired else {
            throw DownloadFailureReason.sessionInitializationFailed(
                "Brak wolnego miejsca: wymagane \(DownloadManifestItem.formatBytes(minimumRequired)), dostepne \(DownloadManifestItem.formatBytes(availableBytes))."
            )
        }
    }

    func prepareSessionDirectories() throws {
        let sessionID = UUID().uuidString.lowercased()
        let rootURL = downloaderSessionsRootURL()
            .appendingPathComponent(sessionID, isDirectory: true)
        let payloadURL = rootURL.appendingPathComponent("payload", isDirectory: true)
        let outputURL = rootURL.appendingPathComponent("output", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: payloadURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: outputURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw DownloadFailureReason.sessionInitializationFailed(error.localizedDescription)
        }

        activeSessionID = sessionID
        activeSessionRootURL = rootURL
        activeSessionPayloadURL = payloadURL
        activeSessionOutputURL = outputURL
    }

    func shouldRetainSessionFilesForDebugMode() -> Bool {
        #if DEBUG
        return preserveDownloadedFilesInDebug
        #else
        return false
        #endif
    }

    func downloaderSessionsRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macUSB_temp", isDirectory: true)
            .appendingPathComponent("downloads", isDirectory: true)
    }
}
