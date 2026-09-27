import SwiftUI

/// 设置页：主题选择、编辑器选项、服务器管理、关于。
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject var servers: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var showServerManager = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $settings.followSystemTheme) {
                        Text("跟随系统配色")
                    }
                    .onChange(of: settings.followSystemTheme) { _, enabled in
                        // 打开时沿用当前主题所在的配色方案家族
                        if enabled {
                            settings.themeFamily = ThemeManager.familyName(of: settings.themeName)
                        }
                    }
                    if settings.followSystemTheme {
                        ForEach(ThemeManager.families, id: \.self) { family in
                            familyRow(family)
                        }
                    } else {
                        ForEach(ThemeManager.bundled, id: \.file.displayName) { bundled in
                            themeRow(bundled)
                        }
                    }
                } header: {
                    Text("主题")
                }

                Section {
                    NavigationLink {
                        List(MonoFont.allCases) { font in
                            Button {
                                settings.monoFont = font
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(font.displayName)
                                            .font(font.font(size: 15))
                                            .foregroundStyle(.primary)
                                        Text(font.note)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if settings.monoFont == font {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        .navigationTitle(Text("字体"))
                    } label: {
                        HStack {
                            Text("字体")
                            Spacer()
                            Text(settings.monoFont.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("字号")
                        Spacer()
                        Stepper(
                            "\(Int(settings.fontSize))",
                            value: $settings.fontSize,
                            in: 10.0...24.0,
                            step: 1
                        )
                    }
                    Toggle(isOn: $settings.showLineNumbers) {
                        Text("显示行号")
                    }
                    Toggle(isOn: $settings.wordWrap) {
                        Text("自动换行")
                    }
                    HStack {
                        Text("Tab宽度")
                        Spacer()
                        Stepper(
                            "\(Int(settings.tabWidth))",
                            value: $settings.tabWidth,
                            in: 2.0...8.0,
                            step: 2
                        )
                    }
                    Toggle(isOn: $settings.showInvisibles) {
                        Text("显示不可见字符")
                    }
                } header: {
                    Text("编辑器")
                }

                Section {
                    Button {
                        showServerManager = true
                    } label: {
                        HStack {
                            Text("管理服务器")
                            Spacer()
                            Text("\(servers.servers.count)")
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("远程")
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0")
                            .foregroundStyle(.secondary)
                    }
                    Text("编辑器内核 Runestone，主题来自 CodeEdit")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("关于")
                }

                Section {
                    NavigationLink {
                        DebugLogView()
                    } label: {
                        Text("调试日志")
                    }
                } header: {
                    Text("调试")
                }
            }
            .navigationTitle(Text("设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("完成") }
                }
            }
            .sheet(isPresented: $showServerManager) {
                ServerManagerView(workspace: workspace, servers: servers)
            }
        }
    }

    private func themeRow(_ bundled: BundledTheme) -> some View {
        let isSelected = settings.themeName == bundled.file.displayName
        return Button {
            settings.themeName = bundled.file.displayName
        } label: {
            HStack(spacing: 12) {
                previewCircles(bundled: bundled)
                Text(bundled.file.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 跟随系统配色时的配色方案行：深/浅两套三色预览，点选即选中该家族。
    private func familyRow(_ family: String) -> some View {
        let isSelected = settings.themeFamily == family
        return Button {
            settings.themeFamily = family
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    ForEach([true, false], id: \.self) { dark in
                        if let bundled = ThemeManager.bundled.first(where: {
                            $0.file.displayName == "\(family) (\(dark ? "Dark" : "Light"))"
                        }) {
                            previewCircles(bundled: bundled)
                        }
                    }
                }
                Text(family)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 三色预览：背景 / 文字 / 关键字。
    private func previewCircles(bundled: BundledTheme) -> some View {
        HStack(spacing: -7) {
            Circle()
                .fill(Color(uiColor: bundled.previewBackground))
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(.gray.opacity(0.35), lineWidth: 1))
            Circle()
                .fill(Color(uiColor: bundled.previewText))
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(.gray.opacity(0.35), lineWidth: 1))
            Circle()
                .fill(Color(uiColor: bundled.previewKeyword))
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(.gray.opacity(0.35), lineWidth: 1))
        }
    }
}
