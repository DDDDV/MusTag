import Foundation

/// Process-wide coordination shared by the model, downloads and Wi-Fi receivers.
/// Network transfers retain a lease until their final local write has finished.
final class LocalLibraryAccess: @unchecked Sendable {
    static let shared = LocalLibraryAccess()
    private let lock = NSLock()
    private var readers: [String: Set<UUID>] = [:]
    private var deletions: [String: UUID] = [:]

    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseAction: (() -> Void)?
        init(_ release: @escaping () -> Void) { releaseAction = release }
        func release() {
            lock.lock()
            let action = releaseAction
            releaseAction = nil
            lock.unlock()
            action?()
        }
        deinit { release() }
    }

    func acquire(_ root: URL, deleting: Bool = false) throws -> Lease {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        let id = UUID()
        lock.lock()
        guard deletions[key] == nil, !deleting || readers[key, default: []].isEmpty else {
            lock.unlock()
            throw MusTagError.message(L10n.text(
                "Finish or cancel the current transfer or file operation before deleting. Close any open deletion confirmation before starting another operation.",
                "请先完成或取消正在进行的传输或文件操作，再删除。开始其他操作前，请关闭已打开的删除确认。"))
        }
        if deleting { deletions[key] = id }
        else { readers[key, default: []].insert(id) }
        lock.unlock()
        return Lease { [self] in
            lock.lock()
            if deleting { if deletions[key] == id { deletions.removeValue(forKey: key) } }
            else {
                readers[key]?.remove(id)
                if readers[key]?.isEmpty == true { readers.removeValue(forKey: key) }
            }
            lock.unlock()
        }
    }
}
