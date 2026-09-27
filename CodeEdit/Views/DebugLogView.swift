import SwiftUI

/// 调试日志查看页：显示、复制、清空内存日志。
struct DebugLogView: View {
    @State private var logText: String = ""
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(logText.isEmpty ? "（暂无日志）" : logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            Divider()
            HStack {
                Button("刷新") {
                    logText = DebugLog.shared.all()
                }
                Spacer()
                if copied {
                    Text("已复制")
                        .foregroundStyle(.secondary)
                }
                Button("复制") {
                    UIPasteboard.general.string = DebugLog.shared.all()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                }
                Button("清空", role: .destructive) {
                    DebugLog.shared.clear()
                    logText = ""
                }
            }
            .padding()
        }
        .navigationTitle("调试日志")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            logText = DebugLog.shared.all()
        }
    }
}
