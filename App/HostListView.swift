import SwiftUI
import DuoVNCKit
import DuoVNCSession
import RFBCore

/// A session to open full screen.
struct SessionLaunch: Identifiable {
    let id: UUID = UUID()
    let endpoint: SessionEndpoint
    let title: String
}

/// Request to open the add/edit sheet.
struct HostEditRequest: Identifiable {
    let id: UUID = UUID()
    var host: SavedHost
    var isNew: Bool
    /// Shown at the top of the sheet (e.g. "请先填写密码").
    var reason: String?
}

/// A LAN / unknown-name host waiting for "仍然连接".
struct PolicyPrompt: Identifiable {
    let id: UUID = UUID()
    let host: SavedHost
    let note: String
}

struct HostListView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: HostEditRequest? = nil
    @State private var launch: SessionLaunch? = nil
    @State private var policyPrompt: PolicyPrompt? = nil
    @State private var blockedMessage: String? = nil
    @AppStorage(SessionSettings.explicitShiftKey) private var explicitShift: Bool = false
    @AppStorage(SessionSettings.naturalScrollingKey) private var naturalScrolling: Bool = true
    @AppStorage(SessionSettings.directTapZoomKey) private var directTapZoom: Double = 4.0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.hosts) { host in
                        Button {
                            connect(host)
                        } label: {
                            HostRow(host: host)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                model.delete(host)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                editing = HostEditRequest(host: host, isNew: false, reason: nil)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                editing = HostEditRequest(host: host, isNew: false, reason: nil)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                model.delete(host)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                    if model.hosts.isEmpty {
                        Text("还没有主机。点右上角的 + 添加你的 Mac。")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("我的 Mac")
                } footer: {
                    Text("轻点连接，左滑编辑或删除。建议用 Tailscale 地址（100.x.x.x）。")
                }

                Section {
                    Button {
                        launch = SessionLaunch(endpoint: SessionEndpoint.demo, title: "演示模式")
                    } label: {
                        Label("演示模式", systemImage: "play.rectangle")
                    }
                } footer: {
                    Text("内置的假桌面，不联网。可以练习瞄准、点击和打字，点中的按钮会变绿。")
                }

                Section {
                    Toggle("大写字母和符号显式按 Shift", isOn: $explicitShift)
                    Toggle("自然滚动", isOn: $naturalScrolling)
                    Stepper(value: $directTapZoom, in: 2.0...16.0, step: 1.0) {
                        Text("放大到 \(Int(directTapZoom)) 倍后，轻点直接点击")
                    }
                } header: {
                    Text("设置")
                } footer: {
                    Text("没放大时，轻点只移动光标，再按「点击」才点下去，这样不容易点错。如果 Mac 上打出的大写字母或符号不对，打开第一项再试。")
                }
            }
            .navigationTitle("Duo VNC")
            .onAppear {
                // Development aid: `-DuoVNCDemo` (e.g. `xcrun simctl launch booted com.lanjunq.duovnc -DuoVNCDemo`)
                // opens demo mode directly.
                if launch == nil && ProcessInfo.processInfo.arguments.contains("-DuoVNCDemo") {
                    launch = SessionLaunch(endpoint: SessionEndpoint.demo, title: "演示模式")
                }
                #if DEBUG
                // Development aid for simulator runs without touch input: connect straight to a Mac
                // from environment variables (pass them with the SIMCTL_CHILD_ prefix). The pinned key
                // skips the trust prompt. Debug builds only; nothing is stored.
                let env: [String: String] = ProcessInfo.processInfo.environment
                if launch == nil, let autoHost = env["DUOVNC_AUTO_HOST"], let autoUser = env["DUOVNC_AUTO_USER"],
                   let autoPass = env["DUOVNC_AUTO_PASS"] {
                    let saved = SavedHost(displayName: autoHost, host: autoHost, username: autoUser,
                                          authKind: .macAccount, knownHostKeySHA256: env["DUOVNC_AUTO_KEY"])
                    launch = SessionLaunch(endpoint: SessionEndpoint.remote(
                        host: saved, credential: RFBCredential.macAccount(username: autoUser, password: autoPass)),
                        title: autoHost)
                }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = HostEditRequest(host: SavedHost(displayName: "", host: ""), isNew: true, reason: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加主机")
                }
            }
            .sheet(item: $editing) { request in
                HostEditView(request: request)
                    .environmentObject(model)
            }
            .fullScreenCover(item: $launch) { item in
                SessionScreen(launch: item, onClose: { launch = nil })
                    .environmentObject(model)
                    .ignoresSafeArea()
                    .statusBarHidden(true)
                    .persistentSystemOverlays(.hidden)
                    .defersSystemGestures(on: .all)
            }
            .alert("连接未加密", isPresented: policyPromptShown, presenting: policyPrompt) { prompt in
                Button("仍然连接") { start(prompt.host) }
                Button("取消", role: .cancel) { }
            } message: { prompt in
                Text(prompt.note)
            }
            .alert("不能连接", isPresented: blockedShown) {
                Button("好", role: .cancel) { }
            } message: {
                Text(blockedMessage ?? "")
            }
            .alert("出错了", isPresented: errorShown) {
                Button("好", role: .cancel) { }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var policyPromptShown: Binding<Bool> {
        Binding<Bool>(get: { policyPrompt != nil }, set: { shown in if !shown { policyPrompt = nil } })
    }

    private var blockedShown: Binding<Bool> {
        Binding<Bool>(get: { blockedMessage != nil }, set: { shown in if !shown { blockedMessage = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding<Bool>(get: { model.errorMessage != nil }, set: { shown in if !shown { model.errorMessage = nil } })
    }

    /// Applies `HostPolicy` before connecting.
    private func connect(_ host: SavedHost) {
        let c: HostPolicy.Classification = HostPolicy.classify(host.host)
        var target: SavedHost = host
        target.host = c.normalizedHost
        switch c.decision {
        case .block:
            blockedMessage = c.note ?? "不允许连接这个地址"
        case .warn:
            policyPrompt = PolicyPrompt(host: target, note: c.note ?? "画面和键盘内容可能未加密")
        case .allow:
            start(target)
        }
    }

    private func start(_ host: SavedHost) {
        guard let credential = model.credential(for: host) else {
            let reason: String = host.authKind == .macAccount ? "请先填写 Mac 用户名和密码" : "请先填写 VNC 密码"
            editing = HostEditRequest(host: host, isNew: false, reason: reason)
            return
        }
        let title: String = host.displayName.isEmpty ? host.host : host.displayName
        launch = SessionLaunch(endpoint: SessionEndpoint.remote(host: host, credential: credential), title: title)
    }
}

private struct HostRow: View {
    let host: SavedHost

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host.displayName.isEmpty ? host.host : host.displayName)
                .font(.body)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let port: String = host.port == 5900 ? "" : ":\(host.port)"
        let auth: String
        switch host.authKind {
        case .macAccount:
            auth = "Mac 账号 \(host.username ?? "")"
        case .vncPassword:
            auth = "VNC 密码"
        }
        return "\(host.host)\(port) · \(auth)"
    }
}
