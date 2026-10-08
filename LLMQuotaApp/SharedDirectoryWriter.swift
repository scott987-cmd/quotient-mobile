import Foundation

/// 共享目录唯一的命令写入口。
///
/// actor 让写入串行化；它自己的执行器不会占用主线程。所有文件都用原子替换，
/// Mac 端不会在 iCloud 正同步到一半时读到半份 JSON。
actor SharedDirectoryWriter {
    func write(_ data: Data, root: URL, directory: String, filename: String) throws {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }

        let dir = root.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(filename), options: .atomic)
    }
}
