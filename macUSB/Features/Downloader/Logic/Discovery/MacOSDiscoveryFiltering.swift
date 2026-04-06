import Foundation

extension MacOSCatalogService {
    func isLegacyAssemblyTarget(_ entry: MacOSInstallerEntry) -> Bool {
        let normalized = entry.name.lowercased()
        if normalized.contains("catalina"), entry.version.hasPrefix("10.15") {
            return true
        }
        if normalized.contains("mojave"), entry.version.hasPrefix("10.14") {
            return true
        }
        if normalized.contains("high sierra"), entry.version.hasPrefix("10.13") {
            return true
        }
        return false
    }

    func filterLegacyAssemblyDescriptors(_ descriptors: [CatalogPackageDescriptor]) -> [CatalogPackageDescriptor] {
        let requiredIDs = Set(Constants.legacyAssemblyRequiredPackageIdentifiers.map { $0.lowercased() })
        let requiredNames = Set(Constants.legacyAssemblyRequiredFileNames.map { $0.lowercased() })

        var filtered = descriptors.filter { descriptor in
            if let packageIdentifier = descriptor.packageIdentifier?.lowercased(), requiredIDs.contains(packageIdentifier) {
                return true
            }
            return requiredNames.contains(descriptor.url.lastPathComponent.lowercased())
        }

        let idPriority = Dictionary(
            uniqueKeysWithValues: Constants.legacyAssemblyRequiredPackageIdentifiers.enumerated().map { ($1.lowercased(), $0) }
        )
        let namePriority = Dictionary(
            uniqueKeysWithValues: Constants.legacyAssemblyRequiredFileNames.enumerated().map { ($1.lowercased(), $0) }
        )

        filtered.sort { lhs, rhs in
            let lhsRank = lhs.packageIdentifier.flatMap { idPriority[$0.lowercased()] }
                ?? namePriority[lhs.url.lastPathComponent.lowercased()]
                ?? Int.max
            let rhsRank = rhs.packageIdentifier.flatMap { idPriority[$0.lowercased()] }
                ?? namePriority[rhs.url.lastPathComponent.lowercased()]
                ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.name < rhs.name
        }

        return filtered
    }

    func deduplicated(_ entries: [MacOSInstallerEntry]) -> [MacOSInstallerEntry] {
        var seen: Set<String> = []
        var result: [MacOSInstallerEntry] = []
        result.reserveCapacity(entries.count)

        for entry in entries {
            let key = "\(entry.name)|\(entry.version)|\(entry.build)"
            if seen.insert(key).inserted {
                result.append(entry)
            }
        }

        return result
    }

    func isDownloadAssetURL(_ url: URL) -> Bool {
        Constants.downloadableExtensions.contains(url.pathExtension.lowercased())
    }
}
