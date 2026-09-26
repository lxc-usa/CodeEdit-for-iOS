import SwiftUI

/// 添加 / 编辑服务器。密码只写入 Keychain。
@MainActor
struct ServerFormView: View {
    @ObservedObject var servers: ServerStore
    let server: ServerConfig?

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && (Int(port) != nil)
            && (server != nil || !password.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称，如：我的 VPS", text: $name)
                    TextField("主机，如：example.com", text: $host)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
                Section("认证") {
                    SecureField(server == nil ? "密码" : "密码（留空则不修改）", text: $password)
                    Text("密码仅保存在本机 Keychain 中，不会上传或记录到日志。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section("安全") {
                    Text("首次连接时会记录服务器的主机密钥；之后若主机密钥发生变化，连接将被拒绝。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(server == nil ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .disabled(!isValid)
                }
            }
            .presentationDetents([.medium, .large])
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        guard let server else { return }
        name = server.name
        host = server.host
        port = String(server.port)
        username = server.username
    }

    private func save() {
        guard let portNumber = Int(port.trimmingCharacters(in: .whitespaces)) else { return }
        if let server {
            var updated = server
            updated.name = name.trimmingCharacters(in: .whitespaces)
            updated.host = host.trimmingCharacters(in: .whitespaces)
            updated.port = portNumber
            updated.username = username.trimmingCharacters(in: .whitespaces)
            servers.update(updated, password: password.isEmpty ? nil : password)
            // 配置变更后断开旧连接，下次使用新配置重连
            Task { await SSHManager.shared.disconnect(serverID: server.id) }
        } else {
            let newServer = ServerConfig(
                name: name.trimmingCharacters(in: .whitespaces),
                host: host.trimmingCharacters(in: .whitespaces),
                port: portNumber,
                username: username.trimmingCharacters(in: .whitespaces)
            )
            servers.add(newServer, password: password)
        }
        dismiss()
    }
}
