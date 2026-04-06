import Foundation

extension MontereyDownloadFlowModel {
    func runBlockingOperation(
        _ operation: @escaping () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func runProcessAndCaptureOutputOffMain(
        executable: String,
        arguments: [String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try Self.runProcessAndCaptureOutputBlocking(
                        executable: executable,
                        arguments: arguments
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    func runProcessAndCaptureOutput(
        executable: String,
        arguments: [String]
    ) throws -> String {
        try Self.runProcessAndCaptureOutputBlocking(
            executable: executable,
            arguments: arguments
        )
    }

    private static func runProcessAndCaptureOutputBlocking(
        executable: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw DownloadFailureReason.assemblyFailed(
                "Nie udalo sie uruchomic \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)"
            )
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let merged = ([output, errors].filter { !$0.isEmpty }).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !merged.isEmpty {
            AppLogging.info(
                "legacy-assembly command \(URL(fileURLWithPath: executable).lastPathComponent): \(merged)",
                category: "Downloader"
            )
        }

        guard process.terminationStatus == 0 else {
            throw DownloadFailureReason.assemblyFailed(
                "Polecenie \(URL(fileURLWithPath: executable).lastPathComponent) zakonczone bledem (\(process.terminationStatus))."
            )
        }

        return merged
    }
}
