import SwiftUI

/// 设置页：主题选择、编辑器选项、关于。
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ThemeManager.bundled, id: \.file.displayName) { bundled in
                        themeRow(bundled)
                    }
                } header: {
                    Text("主题")
                }

                Section {
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
            }
            .navigationTitle(Text("设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("完成") }
                }
            }
        }
    }

    private func themeRow(_ bundled: BundledTheme) -> some View {
        let isSelected = settings.themeName == bundled.file.displayName
        return Button {
            settings.themeName = bundled.file.displayName
        } label: {
            HStack(spacing: 12) {
                // 三色预览：背景 / 文字 / 关键字
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
}
