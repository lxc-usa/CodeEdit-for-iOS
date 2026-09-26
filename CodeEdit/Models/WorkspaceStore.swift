import Foundation
import SwiftUI

/// 工作区：管理 Documents 目录的文件树、打开的文档、自动保存。
@MainActor
final class WorkspaceStore: ObservableObject {
    /// 可打开编辑的文件大小上限（1MB）。
    private static let maxOpenableSize = 1_000_000

    let rootURL: URL
    @Published var rootItem: FileItem
    @Published var openDocuments: [EditorDocument] = []
    @Published var selectedDocument: EditorDocument?
    /// 非空时由界面弹出提示框。
    @Published var alertMessage: String?

    private var saveWorkItems: [String: DispatchWorkItem] = [:]

    // MARK: - 工作区位置（把整个文件夹当工作区打开，CodeEdit 桌面版理念：没有“导入”，只有“打开文件夹”）
    //
    // iOS 要点：.withSecurityScope 是 macOS-only，iOS 上不可用（Xcode 直接报错）。
    // 来自文件选择器的 URL 本身就带 security scope：创建 bookmark 前先
    // startAccessingSecurityScopedResource()，解析后也先 startAccessing，scope
    // 会隐式保留在 bookmark 数据里；options 用 [] 即可。

    /// 持久化的工作区记录（本地 Documents 之外）。
    struct SavedWorkspace: Codable {
        var id: UUID
        var name: String
        var bookmark: Data
    }

    /// 解析后的工作区：持有 security-scoped 访问直到被移除或进程结束。
    final class ResolvedWorkspace: Identifiable {
        let id: UUID
        var name: String
        var bookmark: Data
        let url: URL
        init(id: UUID, name: String, bookmark: Data, url: URL) {
            self.id = id
            self.name = name
            self.bookmark = bookmark
            self.url = url
        }
    }

    private static let savedWorkspacesKey = "codeedit.savedWorkspaces"
    private static let activeWorkspaceKey = "codeedit.activeWorkspace"

    /// 当前工作区显示名（本地=“本地文件”，外部=文件夹名）。
    @Published var workspaceName: String = ""
    /// 已保存的外部工作区（仅保留解析成功、可用的）。
    @Published var savedWorkspaces: [ResolvedWorkspace] = []
    /// 当前工作区 id；nil = 本地 Documents。
    @Published var activeWorkspaceId: UUID?
    var isLocalWorkspace: Bool { activeWorkspaceId == nil }

    init() {
        rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootItem = FileItem(url: rootURL, isDirectory: true)
        workspaceName = NSLocalizedString("本地文件", comment: "Local workspace name")
        refresh(item: rootItem)
        loadSavedWorkspaces()
        restoreActiveWorkspace()
        seedWelcomeIfNeeded()
    }

    // MARK: - 文件树

    /// 递归加载文件夹的全部 children。文件夹在前、文件在后，各自按系统排序。
    func refresh(item: FileItem) {
        guard item.isDirectory else { return }
        var items: [FileItem] = []
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: item.url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for url in urls {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let child = FileItem(url: url, isDirectory: isDir)
                if isDir { refresh(item: child) }
                items.append(child)
            }
        } catch {
            // 读失败则置空，不崩溃
        }
        items.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        // 非文件夹保持 children 为 nil
        item.children = item.isDirectory ? items : nil
    }

    /// 在文件树中按 URL 查找节点。
    func findItem(at url: URL) -> FileItem? {
        findItem(at: url, in: rootItem)
    }

    /// 在文件树中按 id（= url.path）查找节点，供侧边栏 selection 用。
    func findItem(withID id: String) -> FileItem? {
        findItem(withID: id, in: rootItem)
    }

    private func findItem(withID id: String, in item: FileItem) -> FileItem? {
        if item.id == id { return item }
        guard let children = item.children else { return nil }
        for child in children {
            if let found = findItem(withID: id, in: child) { return found }
        }
        return nil
    }

    private func findItem(at url: URL, in item: FileItem) -> FileItem? {
        if item.url == url { return item }
        guard let children = item.children else { return nil }
        for child in children {
            if let found = findItem(at: url, in: child) { return found }
        }
        return nil
    }

    // MARK: - 打开 / 关闭

    func open(_ item: FileItem) {
        guard !item.isDirectory else { return }
        if let doc = openDocuments.first(where: { $0.url == item.url }) {
            selectedDocument = doc
            return
        }
        do {
            let data = try Data(contentsOf: item.url)
            guard data.count <= Self.maxOpenableSize else {
                alertMessage = NSLocalizedString("文件过大，无法打开", comment: "File too large alert")
                return
            }
            guard !data.contains(0) else {
                alertMessage = NSLocalizedString("二进制文件不支持", comment: "Binary file alert")
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            let doc = EditorDocument(url: item.url, text: text)
            openDocuments.append(doc)
            selectedDocument = doc
        } catch {
            alertMessage = NSLocalizedString("无法读取文件", comment: "Cannot read file alert")
        }
    }

    func close(_ doc: EditorDocument) {
        cancelPendingSave(for: doc)
        doc.save()
        guard let idx = openDocuments.firstIndex(where: { $0 === doc }) else { return }
        openDocuments.remove(at: idx)
        if selectedDocument === doc {
            if openDocuments.isEmpty {
                selectedDocument = nil
            } else {
                selectedDocument = openDocuments[min(idx, openDocuments.count - 1)]
            }
        }
    }

    // MARK: - 新建 / 重命名 / 删除

    /// 在重名时自动加序号，返回最终 URL。
    private func uniqueURL(in folder: URL, name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        var i = 1
        let nsName = name as NSString
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = nsName.deletingPathExtension
            let ext = nsName.pathExtension
            let newName = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            i += 1
        }
        return candidate
    }

    func createFile(name: String, in folder: FileItem) {
        let targetFolder = folder.isDirectory ? folder : rootItem
        let url = uniqueURL(in: targetFolder.url, name: name)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil) else { return }
        refresh(item: rootItem)
        treeDidChange()
        if let item = findItem(at: url) { open(item) }
    }

    func createFolder(name: String, in folder: FileItem) {
        let targetFolder = folder.isDirectory ? folder : rootItem
        let url = uniqueURL(in: targetFolder.url, name: name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            return
        }
        refresh(item: rootItem)
        treeDidChange()
    }

    /// 重命名。若有打开的文档位于该路径下（文件本身或文件夹内），先保存关闭再按新路径重开。
    func rename(item: FileItem, newName: String) {
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        guard newURL != item.url,
              !FileManager.default.fileExists(atPath: newURL.path) else { return }
        let oldPath = item.url.path
        let affected = openDocuments.filter {
            $0.url.path == oldPath || $0.url.path.hasPrefix(oldPath + "/")
        }
        // open() 会改动 selectedDocument，先记下重命名前的选中
        let previouslySelectedURL = selectedDocument?.url
        for doc in affected {
            cancelPendingSave(for: doc)
            doc.save()
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: newURL)
        } catch {
            return
        }
        openDocuments.removeAll { doc in affected.contains { $0 === doc } }
        refresh(item: rootItem)
        // 按原顺序重开受影响的文档
        for doc in affected {
            let suffix = String(doc.url.path.dropFirst(oldPath.count))
            let reopenURL = URL(fileURLWithPath: newURL.path + suffix)
            if let newItem = findItem(at: reopenURL) { open(newItem) }
        }
        // 恢复重命名前的选中（若选中的是被重命名的路径，映射到新路径）
        if let prev = previouslySelectedURL {
            let mapped: URL
            if prev.path == oldPath || prev.path.hasPrefix(oldPath + "/") {
                let suffix = String(prev.path.dropFirst(oldPath.count))
                mapped = URL(fileURLWithPath: newURL.path + suffix)
            } else {
                mapped = prev
            }
            selectedDocument = openDocuments.first { $0.url == mapped }
        } else {
            selectedDocument = nil
        }
        treeDidChange()
    }

    func delete(item: FileItem) {
        let path = item.url.path
        let affected = openDocuments.filter {
            $0.url.path == path || $0.url.path.hasPrefix(path + "/")
        }
        let selectedWasAffected = affected.contains { $0 === selectedDocument }
        for doc in affected { cancelPendingSave(for: doc) }
        openDocuments.removeAll { doc in affected.contains { $0 === doc } }
        if selectedWasAffected { selectedDocument = openDocuments.last }
        do {
            try FileManager.default.removeItem(at: item.url)
        } catch {
            return
        }
        refresh(item: rootItem)
        treeDidChange()
    }

    // MARK: - 工作区切换

    private var localWorkspaceName: String {
        NSLocalizedString("本地文件", comment: "Local workspace name")
    }

    /// 从 UserDefaults 加载已保存的工作区：解析 bookmark，stale 则刷新，失败则丢弃。
    private func loadSavedWorkspaces() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedWorkspacesKey),
              let saved = try? JSONDecoder().decode([SavedWorkspace].self, from: data) else { return }
        var refreshed: [SavedWorkspace] = []
        var needsSave = false
        for var record in saved {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: record.bookmark,
                                     options: [],
                                     bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else {
                continue // 解析失败：丢弃该记录
            }
            if stale,
               let fresh = try? url.bookmarkData(options: [],
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil) {
                record.bookmark = fresh
                needsSave = true
            }
            let exists = (try? url.checkResourceIsReachable()) ?? false
            if exists {
                // 访问权为整个 App 会话持有，移除工作区或进程结束时释放
                savedWorkspaces.append(ResolvedWorkspace(id: record.id, name: record.name,
                                                         bookmark: record.bookmark, url: url))
                refreshed.append(record)
            } else {
                url.stopAccessingSecurityScopedResource()
                needsSave = true // 文件夹已不存在：丢弃
            }
        }
        if needsSave { persistWorkspaces(refreshed) }
    }

    private func persistWorkspaces(_ records: [SavedWorkspace]? = nil) {
        let list = records ?? savedWorkspaces.map {
            SavedWorkspace(id: $0.id, name: $0.name, bookmark: $0.bookmark)
        }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.savedWorkspacesKey)
        }
    }

    /// 恢复上次活跃的工作区；若其 bookmark 已失效则回退本地并提示。
    private func restoreActiveWorkspace() {
        guard let idString = UserDefaults.standard.string(forKey: Self.activeWorkspaceKey),
              let id = UUID(uuidString: idString) else { return }
        if let ws = savedWorkspaces.first(where: { $0.id == id }) {
            activateWorkspace(url: ws.url, name: ws.name, id: ws.id, persist: false)
        } else {
            // 上次的工作区已失效（文件夹被移动/删除）：回退本地并提示
            UserDefaults.standard.removeObject(forKey: Self.activeWorkspaceKey)
            alertMessage = NSLocalizedString("工作区不可用，已切回本地文件", comment: "Workspace unavailable fallback")
        }
    }

    /// 切换工作区：保存并关闭全部文档，重建文件树。
    private func activateWorkspace(url: URL, name: String, id: UUID?, persist: Bool = true) {
        saveAll()
        openDocuments.removeAll()
        selectedDocument = nil
        rootItem = FileItem(url: url, isDirectory: true)
        refresh(item: rootItem)
        workspaceName = name
        activeWorkspaceId = id
        if persist {
            if let id {
                UserDefaults.standard.set(id.uuidString, forKey: Self.activeWorkspaceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeWorkspaceKey)
            }
        }
        treeDidChange()
    }

    func openLocalWorkspace() {
        guard !isLocalWorkspace else { return }
        activateWorkspace(url: rootURL, name: localWorkspaceName, id: nil)
    }

    func openWorkspace(_ ws: ResolvedWorkspace) {
        guard activeWorkspaceId != ws.id else { return }
        activateWorkspace(url: ws.url, name: ws.name, id: ws.id)
    }

    /// 从文件夹选择器添加并打开工作区（就地引用，不拷贝）。
    func addWorkspace(from url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return }
        guard let bookmark = try? url.bookmarkData(options: [],
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark,
                                      options: [],
                                      bookmarkDataIsStale: &stale) else { return }
        let path = resolved.standardized.path
        if path == rootURL.standardized.path {
            openLocalWorkspace()
            return
        }
        if let existing = savedWorkspaces.first(where: { $0.url.standardized.path == path }) {
            openWorkspace(existing) // 去重：已在列表中则直接切换
            return
        }
        guard resolved.startAccessingSecurityScopedResource() else { return }
        let record = SavedWorkspace(id: UUID(), name: resolved.lastPathComponent, bookmark: bookmark)
        let ws = ResolvedWorkspace(id: record.id, name: record.name, bookmark: bookmark, url: resolved)
        savedWorkspaces.append(ws)
        persistWorkspaces()
        openWorkspace(ws)
    }

    /// 移除工作区引用（原文件夹及其文件不受影响），若是当前工作区则切回本地。
    func removeWorkspace(_ ws: ResolvedWorkspace) {
        ws.url.stopAccessingSecurityScopedResource()
        savedWorkspaces.removeAll { $0.id == ws.id }
        persistWorkspaces()
        if activeWorkspaceId == ws.id {
            activateWorkspace(url: rootURL, name: localWorkspaceName, id: nil)
        } else {
            treeDidChange()
        }
    }

    /// 树结构变化后显式通知：FileItem.children 的 @Published 没有视图直接观察，
    /// 仅靠 selectedDocument/openDocuments 的连带刷新会漏掉新建文件夹这类操作。
    private func treeDidChange() {
        objectWillChange.send()
    }

    // MARK: - 自动保存

    /// 编辑器内容变化时调用，1.2 秒 debounce 后自动保存。
    func documentDidChange(_ doc: EditorDocument) {
        doc.markDirty()
        saveWorkItems[doc.id]?.cancel()
        let work = DispatchWorkItem { [weak doc] in
            doc?.save()
        }
        saveWorkItems[doc.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func cancelPendingSave(for doc: EditorDocument) {
        saveWorkItems[doc.id]?.cancel()
        saveWorkItems[doc.id] = nil
    }

    /// 切后台时调用，立即保存全部 dirty 文档。
    func saveAll() {
        for (_, work) in saveWorkItems { work.cancel() }
        saveWorkItems.removeAll()
        for doc in openDocuments { doc.save() }
    }

    // MARK: - 首次启动

    private func seedWelcomeIfNeeded() {
        // 仅本地工作区播种样例文件
        guard isLocalWorkspace else { return }
        let flagKey = "codeedit.didSeedWelcome"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        UserDefaults.standard.set(true, forKey: flagKey)
        let existing = try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        guard existing?.isEmpty ?? true else { return }
        let url = rootURL.appendingPathComponent("Welcome.md")
        let content = NSLocalizedString("欢迎页内容", comment: "Seeded welcome file content")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        refresh(item: rootItem)
        if let item = findItem(at: url) { open(item) }
    }
}
