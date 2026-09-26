import SwiftUI
import UniformTypeIdentifiers

/// 左侧文件浏览器：工作区（整个文件夹）的树形列表，新建/重命名/删除/分享。
/// CodeEdit 桌面版理念：没有“导入”，只有“打开文件夹”——整个文件夹就是工作区，就地编辑。
/// 远程工作区（SFTP）打开后与本地走同一套 UI 流程：树形浏览、打开编辑、自动保存、
/// 新建/重命名/删除，经 RemoteFileSystem 直接操作远端。
/// 在 iPhone 抽屉里使用时，通过 onOpenFile 在打开文件后收回抽屉，
/// 通过 onOpenTerminal 把"连接远程主机终端"的请求交到 ContentView 全屏打开。
struct FileBrowserView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var servers: ServerStore
    var onOpenFile: (() -> Void)? = nil
    var onOpenTerminal: ((UUID) -> Void)? = nil

    @State private var showWorkspacePicker = false
    @State private var showRemoteFolderSheet = false
    @State private var showTerminalPicker = false
    @State private var showServerManager = false
    @State private var namePrompt: NamePrompt?
    @State private var deleteItem: FileItem?
    @State private var showDeleteConfirm = false
    @State private var shareItem: ShareItem?

    var body: some View {
        // selection 驱动 NavigationSplitView：iPhone 折叠模式下点行自动推入详情页，
        // iPad 上保持侧边栏高亮与详情同步。数据源是 selectedDocument，标签页切换也会同步。
        // 远程目录的子节点是懒加载的：初始挂"加载中…"占位节点撑起 disclosure，
        // 展开时占位行的 .task 触发真实加载（见 FileRow）。
        List(workspace.rootItem.children ?? [], children: \.children, selection: fileSelection) { item in
            FileRow(item: item)
                .contentShape(Rectangle())
                .contextMenu {
                    if !item.isLoadingPlaceholder {
                        contextMenu(for: item)
                    }
                }
        }
        .listStyle(.sidebar)
        .navigationTitle(navigationTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                workspaceMenu
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        namePrompt = NamePrompt(
                            title: NSLocalizedString("新建文件", comment: ""),
                            placeholder: NSLocalizedString("文件名", comment: ""),
                            initialName: defaultNewFileName(),
                            confirmTitle: NSLocalizedString("创建", comment: "")
                        ) { name in
                            workspace.createFile(name: name, in: workspace.rootItem)
                        }
                    } label: {
                        Label("新建文件", systemImage: "doc.badge.plus")
                    }
                    Button {
                        namePrompt = NamePrompt(
                            title: NSLocalizedString("新建文件夹", comment: ""),
                            placeholder: NSLocalizedString("文件夹名", comment: ""),
                            initialName: NSLocalizedString("新建文件夹", comment: ""),
                            confirmTitle: NSLocalizedString("创建", comment: "")
                        ) { name in
                            workspace.createFolder(name: name, in: workspace.rootItem)
                        }
                    } label: {
                        Label("新建文件夹", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Label("新建", systemImage: "plus")
                }
            }
        }
        .sheet(item: $namePrompt) { prompt in
            NamePromptView(prompt: prompt)
        }
        .confirmationDialog(
            Text("删除确认"),
            isPresented: $showDeleteConfirm,
            presenting: deleteItem
        ) { item in
            Button(role: .destructive) {
                workspace.delete(item: item)
            } label: {
                Text("删除")
            }
        } message: { item in
            Text(String(
                format: NSLocalizedString("删除后无法恢复，确定删除“%@”吗？", comment: "Delete confirmation message"),
                item.name
            ))
        }
        .sheet(item: $shareItem) { item in
            ActivityView(url: item.url)
        }
        .fileImporter(
            isPresented: $showWorkspacePicker,
            // 打开文件夹：整个文件夹成为工作区，就地编辑，不拷贝
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { workspace.addWorkspace(from: url) }
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showRemoteFolderSheet) {
            RemoteFolderSheet(workspace: workspace, servers: servers)
        }
        .sheet(isPresented: $showTerminalPicker) {
            TerminalPickerSheet(servers: servers) { serverID in
                onOpenFile?() // 先收回抽屉
                onOpenTerminal?(serverID)
            }
        }
        .sheet(isPresented: $showServerManager) {
            ServerManagerView(workspace: workspace, servers: servers)
        }
        .alert(
            Text("提示"),
            isPresented: Binding(
                get: { workspace.alertMessage != nil },
                set: { if !$0 { workspace.alertMessage = nil } }
            )
        ) {
            Button(role: .cancel) { } label: { Text("确定") }
        } message: {
            Text(workspace.alertMessage ?? "")
        }
    }

    private var navigationTitle: Text {
        Text(workspace.workspaceName)
    }

    // MARK: - 工作区菜单（含远程）

    @ViewBuilder
    private var workspaceMenu: some View {
        Menu {
            Button {
                workspace.openLocalWorkspace()
            } label: {
                Label("本地文件", systemImage: workspace.isLocalWorkspace ? "checkmark" : "iphone")
            }
            if !workspace.savedWorkspaces.isEmpty {
                Divider()
            }
            ForEach(workspace.savedWorkspaces) { ws in
                Button {
                    workspace.openWorkspace(ws)
                } label: {
                    Label(ws.name, systemImage: workspace.activeWorkspaceId == ws.id ? "checkmark" : "folder")
                }
            }
            Divider()
            Button {
                showWorkspacePicker = true
            } label: {
                Label("打开文件夹…", systemImage: "folder.badge.plus")
            }
            Divider()
            if workspace.isRemoteWorkspace {
                Label(workspace.workspaceName, systemImage: "checkmark")
            }
            Button {
                showRemoteFolderSheet = true
            } label: {
                Label("打开远程文件夹…", systemImage: "server.rack")
            }
            Button {
                showTerminalPicker = true
            } label: {
                Label("连接远程主机终端", systemImage: "terminal")
            }
            Button {
                showServerManager = true
            } label: {
                Label("管理服务器…", systemImage: "gear")
            }
            if workspace.isRemoteWorkspace {
                Divider()
                Button(role: .destructive) {
                    workspace.disconnectRemote()
                    workspace.openLocalWorkspace()
                } label: {
                    Label("断开远程连接", systemImage: "wifi.slash")
                }
            } else if !workspace.isLocalWorkspace {
                Divider()
                Button(role: .destructive) {
                    if let id = workspace.activeWorkspaceId,
                       let ws = workspace.savedWorkspaces.first(where: { $0.id == id }) {
                        workspace.removeWorkspace(ws)
                    }
                } label: {
                    Label("移除此工作区", systemImage: "folder.badge.minus")
                }
            }
        } label: {
            Label("切换工作区", systemImage: "folder")
        }
    }

    // MARK: - 行视图

    /// 侧边栏单选绑定：读侧取当前打开文档对应的行，写侧只接受文件（文件夹点选只展开，不导航）。
    private var fileSelection: Binding<Set<String>> {
        Binding(
            get: {
                guard let url = workspace.selectedDocument?.url,
                      let item = workspace.findItem(at: url) else { return [] }
                return [item.id]
            },
            set: { newIDs in
                guard let id = newIDs.first,
                      let item = workspace.findItem(withID: id),
                      !item.isDirectory, !item.isLoadingPlaceholder else { return }
                workspace.open(item)
                onOpenFile?()
            }
        )
    }

    @ViewBuilder
    private func FileRow(item: FileItem) -> some View {
        if item.isLoadingPlaceholder {
            // 远程目录展开时先看到它，出现即触发该目录的真实加载
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 22)
                Text(item.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .task {
                if let parent = item.parent {
                    await workspace.loadRemoteChildren(of: parent)
                }
            }
        } else {
            let isOpen = workspace.selectedDocument?.url == item.url
            HStack(spacing: 8) {
                Image(systemName: iconName(for: item))
                    .foregroundStyle(item.isDirectory ? .blue : (isOpen ? .accentColor : .secondary))
                    .frame(width: 22)
                Text(item.name)
                    .lineLimit(1)
                    .fontWeight(isOpen ? .semibold : .regular)
            }
        }
    }

    private func iconName(for item: FileItem) -> String {
        if item.isDirectory { return "folder.fill" }
        switch item.url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "html", "htm": return "globe"
        case "md", "markdown", "txt", "text": return "doc.text"
        case "json", "jsonc": return "curlybraces"
        case "py", "js", "ts", "tsx", "java", "c", "cpp", "h", "hpp",
             "cs", "go", "rs", "rb", "php", "sh", "lua", "sql", "yaml", "yml", "toml":
            return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private func contextMenu(for item: FileItem) -> some View {
        if item.isDirectory {
            Button {
                namePrompt = NamePrompt(
                    title: NSLocalizedString("新建文件", comment: ""),
                    placeholder: NSLocalizedString("文件名", comment: ""),
                    initialName: defaultNewFileName(),
                    confirmTitle: NSLocalizedString("创建", comment: "")
                ) { name in
                    workspace.createFile(name: name, in: item)
                }
            } label: {
                Label("新建文件", systemImage: "doc.badge.plus")
            }
            Button {
                namePrompt = NamePrompt(
                    title: NSLocalizedString("新建文件夹", comment: ""),
                    placeholder: NSLocalizedString("文件夹名", comment: ""),
                    initialName: NSLocalizedString("新建文件夹", comment: ""),
                    confirmTitle: NSLocalizedString("创建", comment: "")
                ) { name in
                    workspace.createFolder(name: name, in: item)
                }
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
            Divider()
        } else if !item.isRemote {
            // 分享走系统 ActivityView，需要本地文件 URL，远程文件不支持
            Button {
                shareItem = ShareItem(url: item.url)
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Divider()
        }
        Button {
            namePrompt = NamePrompt(
                title: NSLocalizedString("重命名", comment: ""),
                placeholder: NSLocalizedString("请输入名称", comment: ""),
                initialName: item.name,
                confirmTitle: NSLocalizedString("确定", comment: "")
            ) { name in
                workspace.rename(item: item, newName: name)
            }
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button(role: .destructive) {
            deleteItem = item
            showDeleteConfirm = true
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private func defaultNewFileName() -> String {
        NSLocalizedString("未命名.txt", comment: "Default new file name")
    }
}

// MARK: - 打开远程文件夹

/// 选服务器 + 填远端路径，打开后成为工作区（与本地"打开文件夹"对等）。
struct RemoteFolderSheet: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var servers: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: UUID?
    @State private var path: String = ""
    @State private var showServerManager = false

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    if servers.servers.isEmpty {
                        Button("添加服务器…") { showServerManager = true }
                    } else {
                        ForEach(servers.servers) { server in
                            Button {
                                selectedID = server.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.name)
                                            .foregroundStyle(.primary)
                                        Text(server.displayAddress)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedID == server.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("远程文件夹") {
                    TextField("留空打开主目录，例如 /var/www", text: $path)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
                Section {
                    Text("经 SFTP 打开，之后可像本地一样浏览、编辑、保存，直接操作远端文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(Text("打开远程文件夹"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("取消") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let id = selectedID ?? servers.servers.first?.id
                        if let id, let server = servers.server(id: id) {
                            workspace.openRemoteWorkspace(server: server, path: path)
                        }
                        dismiss()
                    } label: {
                        Text("打开")
                    }
                    .disabled(servers.servers.isEmpty)
                }
            }
            .onAppear {
                if selectedID == nil { selectedID = servers.servers.first?.id }
            }
            .sheet(isPresented: $showServerManager) {
                ServerManagerView(workspace: workspace, servers: servers)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 终端服务器选择

/// 选一台服务器，回调出去由 ContentView 全屏打开终端。
struct TerminalPickerSheet: View {
    @ObservedObject var servers: ServerStore
    var onPick: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if servers.servers.isEmpty {
                    EmptyState(
                        icon: "server.rack",
                        title: "还没有服务器",
                        message: "先添加一台 SSH 服务器，再连接它的终端",
                        actionTitle: nil,
                        action: nil
                    )
                } else {
                    List(servers.servers) { server in
                        Button {
                            dismiss()
                            // 等 sheet 收起再全屏打开终端，避免转场冲突
                            DispatchQueue.main.async {
                                onPick(server.id)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name)
                                        .foregroundStyle(.primary)
                                    Text(server.displayAddress)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "terminal")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(Text("连接远程主机终端"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("取消") }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 服务器管理

/// 服务器增删改（表单复用 openCoder 的 ServerFormView）。
struct ServerManagerView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var servers: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var showAdd = false
    @State private var editing: ServerConfig?
    @State private var pendingDelete: ServerConfig?
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if servers.servers.isEmpty {
                    EmptyState(
                        icon: "server.rack",
                        title: "还没有服务器",
                        message: "添加 SSH 服务器，浏览远程文件、打开远程终端",
                        actionTitle: "添加服务器",
                        action: { showAdd = true }
                    )
                } else {
                    List {
                        ForEach(servers.servers) { server in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name)
                                    .font(.headline)
                                Text(server.displayAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("删除", role: .destructive) {
                                    pendingDelete = server
                                    showDeleteConfirm = true
                                }
                                Button("编辑") { editing = server }
                                    .tint(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text("服务器"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("完成") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: {
                        Label("添加服务器", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                ServerFormView(servers: servers, server: nil)
            }
            .sheet(item: $editing) { server in
                ServerFormView(servers: servers, server: server)
            }
            .confirmationDialog("删除这台服务器？", isPresented: $showDeleteConfirm) {
                Button("删除", role: .destructive) {
                    if let server = pendingDelete {
                        // 若当前远程工作区正连着它，先断开回本地
                        workspace.disconnectRemoteIfNeeded(serverID: server.id)
                        servers.delete(server)
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("服务器配置与 Keychain 中的密码都会被删除。")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 名称输入框

private struct NamePrompt: Identifiable {
    let id = UUID()
    let title: String
    let placeholder: String
    let initialName: String
    let confirmTitle: String
    let onCommit: (String) -> Void
}

private struct NamePromptView: View {
    let prompt: NamePrompt
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(prompt.placeholder, text: $name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .navigationTitle(Text(prompt.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("取消") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        prompt.onCommit(trimmed)
                        dismiss()
                    } label: {
                        Text(prompt.confirmTitle)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
        .onAppear { name = prompt.initialName }
    }
}

// MARK: - 分享

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
