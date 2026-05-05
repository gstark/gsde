import Darwin
import Foundation

enum CEFPath {
    static func canonicalPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let resolved = realPath(path) { return resolved }

        var missingComponents: [String] = []
        var current = URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
        while current.path != "/" {
            missingComponents.insert(current.lastPathComponent, at: 0)
            current.deleteLastPathComponent()
            if let resolvedParent = realPath(current.path) {
                return missingComponents.reduce(resolvedParent) { partial, component in
                    (partial as NSString).appendingPathComponent(component)
                }
            }
        }

        return path
    }

    private static func realPath(_ path: String) -> String? {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &resolved) != nil else { return nil }
        return resolved.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
    }
}
