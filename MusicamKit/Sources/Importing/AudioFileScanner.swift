import Foundation
import UniformTypeIdentifiers

public enum AudioFileScanner {
    /// Containers Core Audio cannot play (architecture, section 8). They are reported, not silently skipped.
    public static let unsupportedExtensions: Set<String> = ["ogg", "oga", "opus"]

    public static func isAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if unsupportedExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio)
    }

    public static func isUnsupported(_ url: URL) -> Bool {
        unsupportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Expands folders recursively and keeps audio files, in a stable order.
    public static func audioFiles(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var inFolder: [URL] = []
                while let next = walker.nextObject() as? URL {
                    if (try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, isAudio(next) {
                        inFolder.append(next)
                    }
                }
                found.append(contentsOf: inFolder.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
            } else if isAudio(url) {
                found.append(url)
            }
        }
        return found
    }
}
