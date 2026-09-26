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

    init() {
        rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootItem = FileItem(url: rootURL, isDirectory: true)
        refresh(item: rootItem)
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

    // MARK: - 新建 / 重命名 / 删除 / 导入

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
    }

    func importFiles(_ urls: [URL], to folder: FileItem) {
        let targetFolder = folder.isDirectory ? folder : rootItem
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            let dest = uniqueURL(in: targetFolder.url, name: url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                continue
            }
        }
        refresh(item: rootItem)
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
