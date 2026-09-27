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
    /// 打开的终端标签（一台服务器最多一个标签，会话由 TerminalSessionCache 按 serverID 持有）。
    @Published var openTerminals: [TerminalTab] = []
    @Published var selectedTerminal: TerminalTab?
    /// 用户手动隐藏了终端键盘：抑制自动重弹（点终端视图任意处恢复，
    /// 切标签时重置）。编辑器不需要此标记（它不会自动抢焦点）。
    @Published var isTerminalKeyboardSuppressed = false
    /// 服务器仓库（CodeEditApp 注入，供终端标签取服务器名）。
    var servers: ServerStore?
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
    /// 当前工作区 id；nil = 本地 Documents（远程工作区另见 remoteFS）。
    @Published var activeWorkspaceId: UUID?
    var isLocalWorkspace: Bool {
        activeWorkspaceId == nil && activeRemoteWorkspaceId == nil && remoteFS == nil
    }
    /// 是否远程工作区（FileBrowserView 用）。
    var isRemoteWorkspace: Bool { remoteFS != nil }
    /// 远程文件系统；非 nil 表示当前是远程工作区（SFTP/WebDAV/…）。
    /// 为保持本地路径零回归，所有文件操作在此分支，本地代码原样不动。
    var remoteFS: (any RemoteFileSystem)?

    init() {
        rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootItem = FileItem(url: rootURL, isDirectory: true)
        workspaceName = NSLocalizedString("本地文件", comment: "Local workspace name")
        refresh(item: rootItem)
        loadSavedWorkspaces()
        loadSavedRemoteWorkspaces()
        restoreActiveWorkspace()
        seedWelcomeIfNeeded()
    }

    // MARK: - 文件树

    /// 递归加载文件夹的全部 children。文件夹在前、文件在后，各自按系统排序。
    /// 远程工作区只加载一层（子目录展开时懒加载），走异步分支。
    func refresh(item: FileItem) {
        if remoteFS != nil {
            Task { await loadRemoteChildren(of: item, force: true) }
            return
        }
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
                child.parent = item
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

    func open(_ item: FileItem, select: Bool = true) {
        guard !item.isDirectory, !item.isLoadingPlaceholder else { return }
        if let doc = openDocuments.first(where: { $0.url == item.url }) {
            if select { selectDocument(doc) }
            return
        }
        if let fs = remoteFS {
            Task { await openRemote(item, fs: fs, select: select) }
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
            if select { selectDocument(doc) }
        } catch {
            alertMessage = NSLocalizedString("无法读取文件", comment: "Cannot read file alert")
        }
    }

    func close(_ doc: EditorDocument) {
        cancelPendingSave(for: doc)
        guard let idx = openDocuments.firstIndex(where: { $0 === doc }) else { return }
        openDocuments.remove(at: idx)
        if selectedDocument === doc {
            if openDocuments.isEmpty {
                selectDocument(nil)
            } else {
                selectDocument(openDocuments[min(idx, openDocuments.count - 1)])
            }
        }
        // 先从标签页摘掉（UI 即时响应），保存放后台：远程保存是网络 I/O，必须 await
        if doc.remoteFS != nil {
            Task { await doc.saveAndWait() }
        } else {
            doc.save()
        }
    }

    // MARK: - 标签选择（文档 / 终端互斥）

    /// 选中文档标签；传入非 nil 时同时取消终端选中。
    func selectDocument(_ doc: EditorDocument?) {
        selectedDocument = doc
        if doc != nil { selectedTerminal = nil }
    }

    /// 选中终端标签；传入非 nil 时同时取消文档选中。
    func selectTerminal(_ tab: TerminalTab?) {
        selectedTerminal = tab
        if tab != nil {
            selectedDocument = nil
            // 切到终端标签 = 新的输入意图，恢复自动弹键盘
            isTerminalKeyboardSuppressed = false
        }
    }

    // MARK: - 终端标签

    /// 打开服务器终端。同一服务器同时只保留一个标签，已打开则直接切过去。
    /// 终端作为标签页显示在主界面编辑区，与文件标签并列。
    func openTerminal(serverID: UUID) {
        if let tab = openTerminals.first(where: { $0.serverID == serverID }) {
            selectTerminal(tab)
            return
        }
        guard let server = servers?.server(id: serverID) else { return }
        let tab = TerminalTab(serverID: serverID, title: server.name)
        openTerminals.append(tab)
        selectTerminal(tab)
    }

    /// 关闭终端标签。显式关闭 = 真正结束会话：丢弃缓存中的 SSH 会话
    /// （横竖屏切换等视图重建不再经过这里，会话不受影响）。
    func closeTerminal(_ tab: TerminalTab) {
        guard let idx = openTerminals.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasSelected = selectedTerminal?.id == tab.id
        openTerminals.remove(at: idx)
        TerminalSessionCache.shared.discard(serverID: tab.serverID)
        if wasSelected {
            if let next = openTerminals.last {
                selectTerminal(next)
            } else {
                selectedTerminal = nil
                selectedDocument = openDocuments.last
            }
        }
    }

    /// 关闭某台服务器的全部终端标签（删除服务器时调用）。
    func closeTerminals(for serverID: UUID) {
        for tab in openTerminals.filter({ $0.serverID == serverID }) {
            closeTerminal(tab)
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
        if let fs = remoteFS {
            Task { await createRemoteFile(name: name, in: folder, fs: fs) }
            return
        }
        let targetFolder = folder.isDirectory ? folder : rootItem
        let url = uniqueURL(in: targetFolder.url, name: name)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil) else { return }
        refresh(item: rootItem)
        treeDidChange()
        if let item = findItem(at: url) { open(item) }
    }

    func createFolder(name: String, in folder: FileItem) {
        if let fs = remoteFS {
            Task { await createRemoteFolder(name: name, in: folder, fs: fs) }
            return
        }
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
        if item.isRemote {
            Task { await renameRemote(item: item, newName: newName) }
            return
        }
        let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        guard newURL != item.url,
              !FileManager.default.fileExists(atPath: newURL.path) else { return }
        let oldPath = item.url.path
        let affected = openDocuments.filter {
            $0.url.path == oldPath || $0.url.path.hasPrefix(oldPath + "/")
        }
        // open() 会改动选中，先记下重命名前的选中（文档或终端）
        let previouslySelectedURL = selectedDocument?.url
        let previouslySelectedTerminal = selectedTerminal
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
        // 按原顺序重开受影响的文档（终端标签选中时不抢焦点）
        for doc in affected {
            let suffix = String(doc.url.path.dropFirst(oldPath.count))
            let reopenURL = URL(fileURLWithPath: newURL.path + suffix)
            if let newItem = findItem(at: reopenURL) { open(newItem, select: previouslySelectedTerminal == nil) }
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
            selectDocument(openDocuments.first { $0.url == mapped })
        } else if let term = previouslySelectedTerminal {
            selectTerminal(term)
        } else {
            selectDocument(nil)
        }
        treeDidChange()
    }

    func delete(item: FileItem) {
        if item.isRemote {
            Task { await deleteRemote(item: item) }
            return
        }
        let path = item.url.path
        let affected = openDocuments.filter {
            $0.url.path == path || $0.url.path.hasPrefix(path + "/")
        }
        let selectedWasAffected = affected.contains { $0 === selectedDocument }
        for doc in affected { cancelPendingSave(for: doc) }
        openDocuments.removeAll { doc in affected.contains { $0 === doc } }
        if selectedWasAffected { selectDocument(openDocuments.last) }
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
    /// 切到本地工作区时先断开远程连接。
    private func activateWorkspace(url: URL, name: String, id: UUID?, persist: Bool = true) {
        disconnectRemote()
        saveAll()
        openDocuments.removeAll()
        selectDocument(nil) // 终端标签与文件工作区无关，跨工作区保留
        rootItem = FileItem(url: url, isDirectory: true)
        refresh(item: rootItem)
        workspaceName = name
        activeWorkspaceId = id
        // 切到本地工作区：远程工作区的活跃标记一并清除
        // （不断整条 SSH 连接，终端会话不受影响）
        activeRemoteWorkspaceId = nil
        UserDefaults.standard.removeObject(forKey: Self.activeRemoteWorkspaceIdKey)
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

    /// 切后台时调用，立即保存全部 dirty 文档（远程走 await，保证落盘）。
    func saveAll() {
        for (_, work) in saveWorkItems { work.cancel() }
        saveWorkItems.removeAll()
        for doc in openDocuments {
            if doc.remoteFS != nil {
                Task { await doc.saveAndWait() }
            } else {
                doc.save()
            }
        }
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

    // MARK: - 远程工作区（SFTP/WebDAV/FTP/SMB，经 RemoteFileSystem 抽象）

    /// 持久化的远程工作区记录（服务器配置本身由 ServerStore 存）。
    struct SavedRemoteWorkspace: Codable, Identifiable {
        var id: UUID
        var serverID: UUID
        var path: String
        var scheme: String
        /// 保存时的显示名（服务器改名后界面按实时名显示，此为兜底）。
        var name: String
    }

    private static let savedRemoteWorkspacesKey = "codeedit.savedRemoteWorkspaces"
    private static let activeRemoteWorkspaceIdKey = "codeedit.activeRemoteWorkspaceId"

    /// 已保存的远程文件夹（去重：同一服务器同一路径只记一条），抽屉菜单一键切换。
    @Published var savedRemoteWorkspaces: [SavedRemoteWorkspace] = []
    /// 当前远程工作区 id；nil = 非远程工作区。
    @Published var activeRemoteWorkspaceId: UUID?
    /// App 启动恢复只尝试一次（servers 就绪后由 CodeEditApp 调用）。
    private var remoteRestoreAttempted = false

    /// 当前远程工作区的服务器 id（remoteFS 非 nil 时有效）。
    var remoteServerID: UUID? {
        guard remoteFS != nil else { return nil }
        return UUID(uuidString: rootItem.url.host ?? "")
    }

    /// 远程工作区的显示副标题（如 "user@host:22 · /home/user/src"）。
    var remoteSubtitle: String? {
        guard let fs = remoteFS else { return nil }
        return "\(fs.displayName) · \(rootItem.url.path)"
    }

    /// 由合成 URL 反查服务器 id（host 段即 serverID）。
    private func serverID(of item: FileItem) -> UUID {
        UUID(uuidString: item.url.host ?? "") ?? UUID()
    }

    /// 构造远程 FileItem 的合成 URL：<scheme>://<serverID>/<path>。
    static func remoteURL(scheme: String, serverID: UUID, path: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = serverID.uuidString
        c.path = path.hasPrefix("/") ? path : "/" + path
        return c.url!
    }

    /// 打开远程文件夹作为工作区：先连通验证，再切换（与本地"打开文件夹"对等）。
    /// path 为空则打开服务器主目录。打开后记入远程文件夹列表，支持一键切换。
    func openRemoteWorkspace(server: ServerConfig, path: String) {
        Task {
            let fs = SFTPFileSystem(server: server)
            do {
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = trimmed.isEmpty
                    ? try await fs.homeDirectory()
                    : try await SSHManager.shared.realPath(server: server, path: trimmed)
                // 先 await 旧通道丢弃，再建新工作区：同一服务器切工作区时
                // detached 的 drop 会和新工作区的首次列表 racing 误杀通道
                await disconnectRemoteAndWait()
                saveAll()
                openDocuments.removeAll()
                selectDocument(nil) // 终端标签与文件工作区无关，跨工作区保留
                remoteFS = fs
                let url = Self.remoteURL(scheme: fs.urlScheme, serverID: server.id, path: resolved)
                rootItem = FileItem(url: url, isDirectory: true)
                let displayName = Self.remoteDisplayName(serverName: server.name, path: resolved)
                rootItem.name = displayName
                workspaceName = displayName
                activeWorkspaceId = nil
                // 记入远程文件夹列表（同一服务器同一路径去重），抽屉菜单一键切换
                let ref: SavedRemoteWorkspace
                if let existing = savedRemoteWorkspaces.first(where: {
                    $0.serverID == server.id && $0.path == resolved
                }) {
                    ref = existing
                } else {
                    ref = SavedRemoteWorkspace(
                        id: UUID(), serverID: server.id, path: resolved,
                        scheme: fs.urlScheme, name: displayName
                    )
                    savedRemoteWorkspaces.append(ref)
                    savedRemoteWorkspaces.sort {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                    persistRemoteWorkspaces()
                }
                activeRemoteWorkspaceId = ref.id
                UserDefaults.standard.set(ref.id.uuidString, forKey: Self.activeRemoteWorkspaceIdKey)
                await loadRemoteChildren(of: rootItem, force: true)
                treeDidChange()
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    /// 远程文件夹显示名：根目录显示服务器名，否则"服务器名 / 文件夹名"。
    static func remoteDisplayName(serverName: String, path: String) -> String {
        path == "/" ? serverName : "\(serverName) / \(URL(fileURLWithPath: path).lastPathComponent)"
    }

    /// 远程文件夹的实时显示名（服务器改名后自动跟随；服务器已删则用保存时的名字）。
    func remoteWorkspaceDisplayName(_ ref: SavedRemoteWorkspace) -> String {
        if let server = servers?.server(id: ref.serverID) {
            return Self.remoteDisplayName(serverName: server.name, path: ref.path)
        }
        return ref.name
    }

    /// 打开已保存的远程文件夹；服务器被删则提示并清理该记录。
    func openSavedRemoteWorkspace(_ ref: SavedRemoteWorkspace) {
        guard activeRemoteWorkspaceId != ref.id else { return }
        guard let server = servers?.server(id: ref.serverID) else {
            savedRemoteWorkspaces.removeAll { $0.id == ref.id }
            persistRemoteWorkspaces()
            if activeRemoteWorkspaceId == ref.id {
                activeRemoteWorkspaceId = nil
                UserDefaults.standard.removeObject(forKey: Self.activeRemoteWorkspaceIdKey)
            }
            alertMessage = NSLocalizedString("服务器已删除", comment: "Server deleted alert")
            treeDidChange()
            return
        }
        openRemoteWorkspace(server: server, path: ref.path)
    }

    /// 移除远程文件夹记录（只删引用，不动远端文件）；若是当前工作区则断开并切回本地。
    func removeRemoteWorkspace(_ ref: SavedRemoteWorkspace) {
        savedRemoteWorkspaces.removeAll { $0.id == ref.id }
        persistRemoteWorkspaces()
        if activeRemoteWorkspaceId == ref.id {
            disconnectRemote()
            activateWorkspace(url: rootURL, name: localWorkspaceName, id: nil)
        } else {
            treeDidChange()
        }
    }

    /// 断开远程文件连接并切回本地。
    /// 只丢 SFTP 通道，不断整条 SSH 连接——终端 PTY 共用这条连接，
    /// 断整条会把正在跑的终端会话一起杀掉。
    func disconnectRemote() {
        guard let fs = remoteFS else { return }
        remoteFS = nil
        if let sftp = fs as? SFTPFileSystem {
            Task { await sftp.disconnect() }
        }
    }

    /// 断开远程文件连接（async 版）：await 旧 SFTP 通道的丢弃再返回。
    ///
    /// openRemoteWorkspace 必须用这个而不是 disconnectRemote()：
    /// 同一服务器切工作区时，旧通道的 drop 若与新工作区的首次列表并发，
    /// 会把新列表正在用的通道提前关掉（NIOCore.ChannelError）。
    func disconnectRemoteAndWait() async {
        guard let fs = remoteFS else { return }
        remoteFS = nil
        if let sftp = fs as? SFTPFileSystem {
            await sftp.disconnect()
        }
    }

    /// 若当前远程工作区属于该服务器，先断开（删服务器时调用），
    /// 该服务器的远程文件夹记录一并清理。
    func disconnectRemoteIfNeeded(serverID: UUID) {
        savedRemoteWorkspaces.removeAll { $0.serverID == serverID }
        persistRemoteWorkspaces()
        if let activeId = activeRemoteWorkspaceId,
           !savedRemoteWorkspaces.contains(where: { $0.id == activeId }) {
            activeRemoteWorkspaceId = nil
            UserDefaults.standard.removeObject(forKey: Self.activeRemoteWorkspaceIdKey)
        }
        if remoteServerID == serverID {
            disconnectRemote()
            activateWorkspace(url: rootURL, name: localWorkspaceName, id: nil)
        } else {
            treeDidChange()
        }
    }

    private func loadSavedRemoteWorkspaces() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedRemoteWorkspacesKey),
              let list = try? JSONDecoder().decode([SavedRemoteWorkspace].self, from: data)
        else { return }
        savedRemoteWorkspaces = list
    }

    private func persistRemoteWorkspaces() {
        if let data = try? JSONEncoder().encode(savedRemoteWorkspaces) {
            UserDefaults.standard.set(data, forKey: Self.savedRemoteWorkspacesKey)
        }
    }

    /// App 启动后恢复上次的远程工作区（由 CodeEditApp 在 servers 就绪后调用一次）。
    func restoreRemoteWorkspaceIfNeeded(servers: ServerStore) {
        guard !remoteRestoreAttempted else { return }
        remoteRestoreAttempted = true
        guard remoteFS == nil,
              let idString = UserDefaults.standard.string(forKey: Self.activeRemoteWorkspaceIdKey),
              let id = UUID(uuidString: idString),
              let ref = savedRemoteWorkspaces.first(where: { $0.id == id }),
              let server = servers.server(id: ref.serverID) else { return }
        openRemoteWorkspace(server: server, path: ref.path)
    }

    // MARK: - 远程文件操作（与本地同语义，异步走网络）

    /// 加载远程目录的一层 children。子目录初始挂"加载中…"占位节点，
    /// 用户展开时由占位行的 .task 触发真实加载（见 FileBrowserView）。
    func loadRemoteChildren(of dir: FileItem, force: Bool = false) async {
        guard let fs = remoteFS, dir.isDirectory, !dir.isLoadingPlaceholder else { return }
        if !force, let kids = dir.children,
           !kids.contains(where: { $0.isLoadingPlaceholder }) { return }
        do {
            let entries = try await fs.list(path: dir.url.path)
            let sid = serverID(of: dir)
            var items: [FileItem] = entries.map { e in
                let child = FileItem(
                    url: Self.remoteURL(scheme: fs.urlScheme, serverID: sid, path: e.path),
                    isDirectory: e.isDirectory
                )
                child.parent = dir
                if e.isDirectory {
                    child.children = [.loadingPlaceholder(parent: child)]
                }
                return child
            }
            items.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            dir.children = items
            treeDidChange()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func openRemote(_ item: FileItem, fs: any RemoteFileSystem, select: Bool = true) async {
        do {
            let data = try await fs.read(path: item.url.path)
            guard data.count <= Self.maxOpenableSize else {
                alertMessage = NSLocalizedString("文件过大，无法打开", comment: "File too large alert")
                return
            }
            guard !data.contains(0) else {
                alertMessage = NSLocalizedString("二进制文件不支持", comment: "Binary file alert")
                return
            }
            // 并发双开保护：等待网络时用户可能又点了一次
            if let existing = openDocuments.first(where: { $0.url == item.url }) {
                if select { selectDocument(existing) }
                return
            }
            let doc = EditorDocument(url: item.url, text: String(data: data, encoding: .utf8) ?? "")
            doc.remoteFS = fs
            openDocuments.append(doc)
            if select { selectDocument(doc) }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// 远程重名时加序号（先 list 再算，与本地 uniqueURL 对等）。
    private func uniqueRemoteName(existing: [String], name: String) -> String {
        guard existing.contains(name) else { return name }
        var i = 1
        let ns = name as NSString
        var candidate = name
        repeat {
            let base = ns.deletingPathExtension
            let ext = ns.pathExtension
            candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            i += 1
        } while existing.contains(candidate)
        return candidate
    }

    private func createRemoteFile(name: String, in folder: FileItem, fs: any RemoteFileSystem) async {
        let targetFolder = (folder.isDirectory && !folder.isLoadingPlaceholder) ? folder : rootItem
        do {
            let entries = try await fs.list(path: targetFolder.url.path)
            let finalName = uniqueRemoteName(existing: entries.map(\.name), name: name)
            let newPath = (targetFolder.url.path as NSString).appendingPathComponent(finalName)
            try await fs.write(path: newPath, data: Data())
            await loadRemoteChildren(of: targetFolder, force: true)
            let url = Self.remoteURL(scheme: fs.urlScheme, serverID: serverID(of: targetFolder), path: newPath)
            if let item = findItem(at: url) { open(item) }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func createRemoteFolder(name: String, in folder: FileItem, fs: any RemoteFileSystem) async {
        let targetFolder = (folder.isDirectory && !folder.isLoadingPlaceholder) ? folder : rootItem
        do {
            let entries = try await fs.list(path: targetFolder.url.path)
            let finalName = uniqueRemoteName(existing: entries.map(\.name), name: name)
            let newPath = (targetFolder.url.path as NSString).appendingPathComponent(finalName)
            try await fs.createDirectory(path: newPath)
            await loadRemoteChildren(of: targetFolder, force: true)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func renameRemote(item: FileItem, newName: String) async {
        guard let fs = remoteFS, !item.isLoadingPlaceholder else { return }
        let parentPath = (item.url.path as NSString).deletingLastPathComponent
        let newPath = (parentPath as NSString).appendingPathComponent(newName)
        guard newPath != item.url.path else { return }
        do {
            // 重名保护：与本地 rename 的 fileExists 检查对等
            let siblings = try await fs.list(path: parentPath)
            guard !siblings.map(\.name).contains(newName) else { return }
            let oldPath = item.url.path
            let affected = openDocuments.filter {
                $0.url.path == oldPath || $0.url.path.hasPrefix(oldPath + "/")
            }
            let previouslySelectedURL = selectedDocument?.url
            let previouslySelectedTerminal = selectedTerminal
            for doc in affected {
                cancelPendingSave(for: doc)
                await doc.saveAndWait()
            }
            try await fs.rename(from: oldPath, to: newPath)
            openDocuments.removeAll { doc in affected.contains { $0 === doc } }
            if let parent = item.parent {
                await loadRemoteChildren(of: parent, force: true)
            }
            let sid = serverID(of: item)
            for doc in affected {
                let suffix = String(doc.url.path.dropFirst(oldPath.count))
                let reopenURL = Self.remoteURL(scheme: fs.urlScheme, serverID: sid, path: newPath + suffix)
                if let newItem = findItem(at: reopenURL) { open(newItem, select: previouslySelectedTerminal == nil) }
            }
            if let prev = previouslySelectedURL {
                let mapped: URL
                if prev.path == oldPath || prev.path.hasPrefix(oldPath + "/") {
                    let suffix = String(prev.path.dropFirst(oldPath.count))
                    mapped = Self.remoteURL(scheme: fs.urlScheme, serverID: sid, path: newPath + suffix)
                } else {
                    mapped = prev
                }
                selectDocument(openDocuments.first { $0.url == mapped })
            } else if let term = previouslySelectedTerminal {
                selectTerminal(term)
            } else {
                selectDocument(nil)
            }
            treeDidChange()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func deleteRemote(item: FileItem) async {
        guard let fs = remoteFS, !item.isLoadingPlaceholder else { return }
        let path = item.url.path
        let affected = openDocuments.filter {
            $0.url.path == path || $0.url.path.hasPrefix(path + "/")
        }
        let selectedWasAffected = affected.contains { $0 === selectedDocument }
        for doc in affected { cancelPendingSave(for: doc) }
        openDocuments.removeAll { doc in affected.contains { $0 === doc } }
        if selectedWasAffected { selectDocument(openDocuments.last) }
        do {
            try await fs.delete(path: path, isDirectory: item.isDirectory)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        if let parent = item.parent {
            await loadRemoteChildren(of: parent, force: true)
        }
        treeDidChange()
    }
}
