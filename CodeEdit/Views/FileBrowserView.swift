import SwiftUI
import UniformTypeIdentifiers

/// 左侧文件浏览器：树形文件列表，新建/重命名/删除/导入/分享。
/// 在 iPhone 抽屉里使用时，通过 onOpenFile 在打开文件后收回抽屉。
struct FileBrowserView: View {
    @ObservedObject var workspace: WorkspaceStore
    var onOpenFile: (() -> Void)? = nil

    @State private var showImporter = false
    @State private var importTarget: FileItem?
    @State private var namePrompt: NamePrompt?
    @State private var deleteItem: FileItem?
    @State private var showDeleteConfirm = false
    @State private var shareItem: ShareItem?

    var body: some View {
        // selection 驱动 NavigationSplitView：iPhone 折叠模式下点行自动推入详情页，
        // iPad 上保持侧边栏高亮与详情同步。数据源是 selectedDocument，标签页切换也会同步。
        List(workspace.rootItem.children ?? [], children: \.children, selection: fileSelection) { item in
            FileRow(item: item)
                .contentShape(Rectangle())
                .contextMenu { contextMenu(for: item) }
        }
        .listStyle(.sidebar)
        .navigationTitle(Text("文件"))
        .toolbar {
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
                    Button {
                        importTarget = nil
                        showImporter = true
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
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
            isPresented: $showImporter,
            // .folder 显式声明后，系统文件选择器允许直接选中整个目录导入；
            // copyItem 本就递归拷贝目录，refresh 也递归重建树。
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                workspace.importFiles(urls, to: importTarget ?? workspace.rootItem)
            case .failure:
                break
            }
            importTarget = nil
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
                      !item.isDirectory else { return }
                workspace.open(item)
                onOpenFile?()
            }
        )
    }

    @ViewBuilder
    private func FileRow(item: FileItem) -> some View {
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
            Button {
                importTarget = item
                showImporter = true
            } label: {
                Label("导入到此文件夹", systemImage: "square.and.arrow.down")
            }
            Divider()
        } else {
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
