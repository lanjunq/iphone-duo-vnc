import SwiftUI
import DuoVNCKit

/// Add / edit one saved host. The password goes to the Keychain, never into the JSON file.
struct HostEditView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let request: HostEditRequest

    @State private var name: String
    @State private var address: String
    @State private var portText: String
    @State private var username: String
    @State private var password: String = ""
    @State private var authKind: HostAuthKind
    @State private var clearPinnedKey: Bool = false

    init(request: HostEditRequest) {
        self.request = request
        _name = State(initialValue: request.host.displayName)
        _address = State(initialValue: request.host.host)
        _portText = State(initialValue: String(request.host.port))
        _username = State(initialValue: request.host.username ?? "")
        _authKind = State(initialValue: request.host.authKind)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let reason = request.reason {
                    Section {
                        Text(reason).foregroundStyle(.orange)
                    }
                }
                Section {
                    TextField("名称，例如 家里的 Mac mini", text: $name)
                    TextField("地址：Tailscale IP 或主机名", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                    if let note = policy.note, !address.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label(note, systemImage: policyIcon)
                            .font(.footnote)
                            .foregroundStyle(policyColor)
                    }
                } header: {
                    Text("主机")
                }

                Section {
                    Picker("登录方式", selection: $authKind) {
                        Text("Mac 账号").tag(HostAuthKind.macAccount)
                        Text("VNC 密码").tag(HostAuthKind.vncPassword)
                    }
                    .pickerStyle(.segmented)
                    if authKind == .macAccount {
                        TextField("Mac 用户名（短名）", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .textContentType(.username)
                    }
                    SecureField(passwordPlaceholder, text: $password)
                        .textContentType(.password)
                } header: {
                    Text("登录")
                } footer: {
                    Text(authKind == .macAccount
                         ? "用 Mac 上的账号密码登录（加密的 Apple 登录方式）。这个账号要在 Mac 的「屏幕共享」里有权限。"
                         : "用屏幕共享里设置的「VNC 显示器密码」登录，最多 8 位。密码只存在本机钥匙串里。")
                }

                if let pinned = request.host.knownHostKeySHA256, !request.isNew {
                    Section {
                        Text(HostKeyTrust.formatted(pinned))
                            .strikethrough(clearPinnedKey)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(clearPinnedKey ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                        Toggle("保存时清除已记住的指纹", isOn: $clearPinnedKey)
                    } header: {
                        Text("主机指纹")
                    } footer: {
                        Text("第一次连接时记住的 Mac 密钥指纹。只有在确认 Mac 重装过系统、指纹确实变了时才清除。")
                    }
                }
            }
            .navigationTitle(request.isNew ? "添加主机" : "编辑主机")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var policy: HostPolicy.Classification {
        HostPolicy.classify(address)
    }

    private var policyIcon: String {
        switch policy.decision {
        case .allow: return "checkmark.shield"
        case .warn: return "exclamationmark.triangle"
        case .block: return "xmark.octagon"
        }
    }

    private var policyColor: Color {
        switch policy.decision {
        case .allow: return .secondary
        case .warn: return .orange
        case .block: return .red
        }
    }

    private var hasSavedPassword: Bool {
        !request.isNew && model.hasPassword(request.host)
    }

    private var passwordPlaceholder: String {
        hasSavedPassword ? "密码（已保存，留空不修改）" : "密码"
    }

    private var port: UInt16? {
        guard let v = Int(portText.trimmingCharacters(in: .whitespaces)), v >= 1, v <= 65535 else { return nil }
        return UInt16(v)
    }

    private var canSave: Bool {
        let a: String = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, port != nil, policy.decision != .block else { return false }
        if authKind == .macAccount && username.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }

    private func save() {
        guard let port = port else { return }
        var host: SavedHost = request.host
        let a: String = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let n: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        host.displayName = n.isEmpty ? a : n
        host.host = a
        host.port = port
        host.authKind = authKind
        host.username = authKind == .macAccount ? username.trimmingCharacters(in: .whitespaces) : nil
        if clearPinnedKey { host.knownHostKeySHA256 = nil }
        model.save(host, password: password)
        password = ""
        dismiss()
    }
}
