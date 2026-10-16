// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Security
import SwiftUI
import UniformTypeIdentifiers

enum JITMethod: String, CaseIterable, Identifiable {
    case automatic
    case stikDebug
    case builtIn

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .stikDebug: return "StikDebug"
        case .builtIn: return "内置 StikJIT"
        }
    }
}

/// Where Built-in StikJIT's pairing file came from.
enum JITPairingSource: String {
    /// Made by Madeira on this device (iOS 27, OnDevicePairing).
    case onDevice
    /// Imported from a file made on a computer.
    case imported
}

/// This iPhone's remote pairing file for Built-in StikJIT. It is a credential
/// for the device itself, so it lives in the Keychain (this device only, while
/// unlocked), as the Steam sign-in token does, and never in Documents, where
/// the Files app and every Windows program in Madeira could read it. Its bytes
/// go only to the bundled helper, over XPC, for one request. A copy an earlier
/// build left at Documents/StikJIT/pairingFile.plist moves into the Keychain
/// and is deleted.
enum JITPairingFileStore {
    private static let service = "MadeiraJITPairing"
    private static let account = "rppairing"
    private static let sourceKey = "madeiraJITPairingSource"

    static var isImported: Bool { (try? data()) != nil }

    /// Files stored before on-device pairing existed were all imported.
    static var source: JITPairingSource? {
        guard isImported else { return nil }
        return UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
    }

    static func data() throws -> Data {
        moveLegacyFile()
        var result: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, !data.isEmpty else {
            throw NSError(domain: "MadeiraJIT", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: "尚未保存这台设备的配对文件。"])
        }
        return data
    }

    static func importFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try store(try Data(contentsOf: source), source: .imported)
    }

    /// Validates an RPPairing plist and makes it the pairing file.
    static func store(_ data: Data, source: JITPairingSource) throws {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            throw NSError(domain: "MadeiraJIT", code: 10,
                          userInfo: [NSLocalizedDescriptionKey:
                            "这不是有效的 StikDebug 远程配对文件。请使用 iloader 生成文件后重试。"])
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(item as CFDictionary)
        var add = item
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "MadeiraJIT", code: 12,
                          userInfo: [NSLocalizedDescriptionKey:
                            "无法将配对文件保存到钥匙串（\(status)）。请解锁设备后重试。"])
        }
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
    }

    /// Documents/StikJIT/pairingFile.plist, where builds before the Keychain kept it.
    private static var legacyFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
    }

    private static func moveLegacyFile() {
        let manager = FileManager.default
        let file = legacyFolder.appendingPathComponent("pairingFile.plist")
        guard manager.fileExists(atPath: file.path), let data = try? Data(contentsOf: file) else { return }
        let kept = UserDefaults.standard.string(forKey: sourceKey).flatMap(JITPairingSource.init(rawValue:)) ?? .imported
        // Deleted only once the Keychain holds it (a locked device keeps it for later).
        if (try? store(data, source: kept)) != nil {
            try? manager.removeItem(at: file)
            if (try? manager.contentsOfDirectory(atPath: legacyFolder.path))?.isEmpty == true {
                try? manager.removeItem(at: legacyFolder)
            }
            LogStore.shared.log("[jit] pairing file moved from Documents into the Keychain")
        }
    }
}

@MainActor
final class JITCoordinator: ObservableObject {
    static let shared = JITCoordinator()

    enum CoordinatorError: LocalizedError {
        case setupRequired(String)
        case pairingMissing
        case scriptMissing

        var errorDescription: String? {
            switch self {
            case .setupRequired(let message): return message
            case .pairingMissing: return "请先配对这台设备，或导入它的配对文件。"
            case .scriptMissing: return "当前安装缺少 Madeira 的 JIT 脚本。请重新安装 Madeira。"
            }
        }
    }

    /// Why the built-in helper could not reach this device, read from its error.
    enum ConnectionProblem: Equatable {
        /// Nothing answered at LocalDevVPN's address: the VPN is off or not routing.
        case vpn
        /// The device closed the connection, usually because it no longer accepts this
        /// pairing (every new pairing replaces the last).
        case pairing

        init?(helperMessage: String) {
            let text = helperMessage.lowercased()
            let has = { (needles: [String]) in needles.contains(where: text.contains) }
            if has(["connectionreset", "connection reset", "device refused connection"]) {
                self = .pairing
            } else if has(["connectionrefused", "connection refused", "timedout", "timed out",
                           "networkunreachable", "network unreachable", "hostunreachable", "host unreachable", "no route"]) {
                self = .vpn
            } else {
                return nil
            }
        }

        var message: String {
            switch self {
            case .vpn:
                return "Madeira 无法连接到这台设备。请连接 LocalDevVPN 后重试。"
            case .pairing:
                return "设备关闭了连接，通常表示它已不再接受 Madeira 的配对。请重新配对，并确认 LocalDevVPN 已连接。"
            }
        }
    }

    @Published var method: JITMethod {
        didSet { UserDefaults.standard.set(method.rawValue, forKey: "madeiraJITMethod") }
    }
    @Published private(set) var connectionProblem: ConnectionProblem?
    /// What the last loopback check found (nil: none ran). A JIT failure after it found no
    /// lockdownd is a LocalDevVPN problem whatever the helper's message says: a network
    /// that accepts any connection makes the helper's read end early ("early eof").
    private var loopbackAnswered: Bool?
    @Published var showSetup = false
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var txmPresent: Bool?
    @Published private(set) var pairingImported = JITPairingFileStore.isImported
    @Published private(set) var pairingSource = JITPairingFileStore.source

    private init() {
        method = UserDefaults.standard.string(forKey: "madeiraJITMethod")
            .flatMap(JITMethod.init(rawValue:)) ?? .automatic
    }

    var resolvedMethod: JITMethod {
        guard method == .automatic else { return method }
        return StikJITHelper.isAvailable ? .stikDebug : .builtIn
    }

    var automaticDescription: String {
        StikJITHelper.isAvailable
            ? "已安装 StikDebug，Madeira 将直接打开它。"
            : "未检测到 StikDebug，Madeira 将使用内置助手。"
    }

    func refreshPairingStatus() {
        pairingImported = JITPairingFileStore.isImported
        pairingSource = JITPairingFileStore.source
    }

    func enable(completion: @escaping (Result<Void, Error>) -> Void) {
        guard SigningStatus.current.debuggable else {
            completion(.failure(NSError(
                domain: "MadeiraJIT", code: 11,
                userInfo: [NSLocalizedDescriptionKey: SigningStatus.notDebuggableMessage])))
            return
        }
        if StikJITHelper.ready {
            completion(.success(()))
            return
        }
        error = nil
        status = nil
        connectionProblem = nil
        ensureLoopback(then: { [weak self] restoreOnFailure in
            self?.enableResolved { result in
                // Nothing will hold the network open now: put back what the shortcut changed.
                if restoreOnFailure, case .failure = result {
                    JITNetworkShortcut.shared.restoreIfNeeded {}
                }
                completion(result)
            }
        }, stopped: { [weak self] message in
            // The shortcut itself failed: say so (no connect action, which would only run
            // it again), skip a JIT attempt that cannot reach the device, and put back
            // whatever it changed before it stopped.
            self?.status = nil
            self?.error = message
            JITNetworkShortcut.shared.restoreIfNeeded {}
            completion(.failure(NSError(domain: "MadeiraJIT", code: 14,
                                        userInfo: [NSLocalizedDescriptionKey: message])))
        })
    }

    /// LocalDevVPN's loopback first (milliseconds when it already works). When it does
    /// not answer and the Madeira JIT shortcut is on, the shortcut turns Cellular Data
    /// off without Wi-Fi and connects LocalDevVPN, and the loopback is checked again
    /// while the VPN settles. Either way JIT is then attempted, so a failure still gets
    /// the usual explanation. `proceed`'s argument: the shortcut ran.
    private func ensureLoopback(then proceed: @escaping (Bool) -> Void, stopped: @escaping (String) -> Void) {
        let vpnWasUp = LoopbackProbe.vpnInterfaceUp
        LoopbackProbe.check { [weak self] probe in
            LogStore.shared.log(String(format: "[jit-loopback] %@ in %.0f ms (vpn-interface=%d, %@)",
                                       probe.reachable ? "reachable" : "unreachable", probe.milliseconds,
                                       vpnWasUp ? 1 : 0, probe.detail))
            self?.loopbackAnswered = probe.reachable
            guard let self, !probe.reachable, JITNetworkShortcut.shared.enabled else { proceed(false); return }
            status = "正在运行 \(JITNetworkShortcut.name) 快捷指令…"
            JITNetworkShortcut.shared.start { [weak self] outcome in
                if case .failed(let why) = outcome {
                    stopped("\(JITNetworkShortcut.name) 快捷指令已停止：\(why) 请在“快捷指令”中检查其步骤后重试。")
                    return
                }
                // LocalDevVPN's Connect returns before its tunnel routes (about 5 s
                // on the 18 Pro): go on the moment lockdownd answers.
                self?.status = "正在等待 LocalDevVPN…"
                let waitStart = CFAbsoluteTimeGetCurrent()
                LoopbackProbe.waitUntilReachable(within: 15) { [weak self] probe in
                    LogStore.shared.log(String(format: "[jit-loopback] after the shortcut: %@ after %.1f s (vpn-interface=%d, %@)",
                                               probe.reachable ? "reachable" : "unreachable",
                                               CFAbsoluteTimeGetCurrent() - waitStart,
                                               LoopbackProbe.vpnInterfaceUp ? 1 : 0, probe.detail))
                    self?.loopbackAnswered = probe.reachable
                    proceed(true)
                }
            }
        }
    }

    /// JIT setup's connect action with the Madeira JIT shortcut on: the shortcut connects
    /// LocalDevVPN (turning Cellular Data off without Wi-Fi); then the loopback is checked.
    func connectWithShortcut() {
        busy = true
        error = nil
        status = "正在运行 \(JITNetworkShortcut.name) 快捷指令…"
        JITNetworkShortcut.shared.start { [weak self] outcome in
            if case .failed(let why) = outcome {
                self?.busy = false
                self?.status = nil
                self?.error = "\(JITNetworkShortcut.name) 快捷指令未能运行：\(why)。"
                return
            }
            LoopbackProbe.waitUntilReachable(within: 15) { [weak self] probe in
                self?.busy = false
                if probe.reachable {
                    self?.connectionProblem = nil
                    self?.status = "LocalDevVPN 已连接到这台设备。"
                } else {
                    self?.status = nil
                    self?.error = ConnectionProblem.vpn.message
                }
            }
        }
    }

    private func enableResolved(_ completion: @escaping (Result<Void, Error>) -> Void) {
        switch resolvedMethod {
        case .automatic:
            assertionFailure("Automatic must resolve to a concrete JIT method")
        case .stikDebug:
            guard StikJITHelper.isAvailable else {
                let message = "尚未安装 StikDebug。请安装它或选择“内置 StikJIT”。"
                error = message
                showSetup = true
                completion(.failure(CoordinatorError.setupRequired(message)))
                return
            }
            busy = true
            status = "正在等待 StikDebug…"
            StikJITHelper.enableJIT { [weak self] result in
                Task { @MainActor in
                    self?.busy = false
                    self?.status = (try? result.get()).map { _ in "StikDebug 已附加。" }
                    if case .failure(let failure) = result { self?.error = failure.localizedDescription }
                    completion(result)
                }
            }
        case .builtIn:
            guard JITPairingFileStore.isImported else {
                let message = "请配对这台设备或导入它的配对文件，以完成内置 StikJIT 设置。"
                error = message
                showSetup = true
                completion(.failure(CoordinatorError.setupRequired(message)))
                return
            }
            enableBuiltIn(completion: completion)
        }
    }

    func importPairingFile(_ source: URL) {
        do {
            try JITPairingFileStore.importFile(from: source)
            OnDevicePairing.shared.cancel()
            refreshPairingStatus()
            status = "已导入配对文件。"
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// OnDevicePairing finished: its file becomes the pairing file and Built-in StikJIT the method.
    func storeOnDevicePairing(_ data: Data) throws {
        try JITPairingFileStore.store(data, source: .onDevice)
        refreshPairingStatus()
        method = .builtIn
        status = "已在 Madeira 中配对。"
        error = nil
    }

    func prepareBuiltIn() {
        guard SigningStatus.current.debuggable else {
            error = SigningStatus.notDebuggableMessage
            return
        }
        guard MadeiraBuiltInJIT.isAvailable else {
            error = MadeiraBuiltInJIT.unavailableReason
            return
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            error = CoordinatorError.pairingMissing.localizedDescription
            return
        }
        busy = true
        error = nil
        connectionProblem = nil
        status = "正在检查 LocalDevVPN 和开发者磁盘映像…"
        MadeiraBuiltInJIT.send(.prepare(pairingData: pairing)) { [weak self] result in
            guard let self else { return }
            busy = false
            switch result {
            case .success(let response):
                txmPresent = response.txmPresent
                status = response.success ? response.message : nil
                error = response.success ? nil : helperFailure(response.message)
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    func enableBuiltIn(completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        guard MadeiraBuiltInJIT.isAvailable else {
            let failure = NSError(
                domain: "MadeiraJIT", code: 12,
                userInfo: [NSLocalizedDescriptionKey:
                    MadeiraBuiltInJIT.unavailableReason ?? "内置 JIT 不可用。"])
            error = failure.localizedDescription
            completion(.failure(failure))
            return
        }
        guard let pairing = try? JITPairingFileStore.data() else {
            error = CoordinatorError.pairingMissing.localizedDescription
            completion(.failure(CoordinatorError.pairingMissing))
            return
        }
        guard let script = StikJITHelper.scriptData else {
            error = CoordinatorError.scriptMissing.localizedDescription
            completion(.failure(CoordinatorError.scriptMissing))
            return
        }

        busy = true
        error = nil
        status = "正在启动 Madeira 的 JIT 助手…"
        var readinessTimer: Timer?
        var readinessFinished = false
        MadeiraBuiltInJIT.send(
            .enable(targetPID: getpid(), pairingData: pairing,
                    scriptBase64: script.base64EncodedString()),
            started: { [weak self] in
                self?.status = "正在等待 Madeira 的 JIT 助手附加…"
                readinessTimer = StikJITHelper.waitForDebugger { [weak self] result in
                    guard !readinessFinished else { return }
                    readinessFinished = true
                    self?.busy = false
                    switch result {
                    case .success:
                        self?.status = "内置 JIT 已附加。"
                        self?.error = nil
                    case .failure(let failure):
                        self?.error = failure.localizedDescription
                    }
                    completion(result)
                }
            },
            completion: { [weak self] result in
                switch result {
                case .success(let response):
                    self?.txmPresent = response.txmPresent
                    LogStore.shared.log("[jit-built-in] \(response.message)",
                                        level: response.success ? .success : .error)
                    if !response.success && !readinessFinished, let self {
                        readinessFinished = true
                        readinessTimer?.invalidate()
                        busy = false
                        let message = helperFailure(response.message)
                        error = message
                        completion(.failure(NSError(
                            domain: "MadeiraJIT", code: 13,
                            userInfo: [NSLocalizedDescriptionKey: message])))
                    }
                case .failure(let failure):
                    if !readinessFinished {
                        readinessFinished = true
                        readinessTimer?.invalidate()
                        self?.busy = false
                        self?.error = failure.localizedDescription
                        completion(.failure(failure))
                    }
                }
            })
    }

    /// The helper's failure as shown: a connection problem gets its plain explanation
    /// (the helper's own message is already in the log).
    private func helperFailure(_ message: String) -> String {
        connectionProblem = ConnectionProblem(helperMessage: message) ?? (loopbackAnswered == false ? .vpn : nil)
        return connectionProblem?.message ?? message
    }

    func resetDDI() {
        busy = true
        error = nil
        status = "正在重置开发者磁盘映像缓存…"
        MadeiraBuiltInJIT.send(.resetDDI) { [weak self] result in
            self?.busy = false
            switch result {
            case .success(let response):
                self?.status = response.success ? response.message : nil
                self?.error = response.success ? nil : response.message
            case .failure(let failure):
                self?.error = failure.localizedDescription
            }
        }
    }
}

/// LocalDevVPN, which built-in JIT and StikDebug reach the device through: open it to
/// connect when it is installed, otherwise its App Store page.
enum LocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    /// `enable` connects the VPN; `scheme` has LocalDevVPN return to Madeira a second later.
    static let connect = URL(string: "localdevvpn://enable?scheme=madeira")!

    static var isInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!) }
    static var actionTitle: String { isInstalled ? "连接 LocalDevVPN" : "获取 LocalDevVPN" }

    static func open() {
        let installed = isInstalled
        LogStore.shared.log("[jit] LocalDevVPN \(installed ? "connect" : "app-store")")
        UIApplication.shared.open(installed ? connect : appStore)
    }
}

/// The fix a JIT connection problem offers: pair again (rejected pairing) and LocalDevVPN.
/// With the Madeira JIT shortcut on, LocalDevVPN is connected by the shortcut, never by
/// its link: `retry` enables JIT again (which runs the shortcut when the loopback does not
/// answer); without it the shortcut runs on its own.
@MainActor func jitConnectionActions(_ problem: JITCoordinator.ConnectionProblem,
                                     retry: (() -> Void)? = nil,
                                     then dismiss: @escaping () -> Void = {}) -> some View {
    Group {
        if problem == .pairing {
            Button(OnDevicePairing.isSupported ? "重新配对" : "打开 JIT 设置") {
                dismiss()
                if OnDevicePairing.isSupported { OnDevicePairing.shared.start() }
                JITCoordinator.shared.showSetup = true
            }
        }
        if JITNetworkShortcut.shared.enabled {
            Button("通过 \(JITNetworkShortcut.name) 连接") {
                dismiss()
                if let retry { retry() } else { JITCoordinator.shared.connectWithShortcut() }
            }
        } else {
            Button(LocalDevVPN.actionTitle) { dismiss(); LocalDevVPN.open() }
        }
    }
}

struct JITSettingsSection: View {
    @ObservedObject private var coordinator = JITCoordinator.shared
    @ObservedObject private var onboarding = OnboardingModel.shared
    @ObservedObject private var shortcut = JITNetworkShortcut.shared

    var body: some View {
        Section {
            Picker("JIT 方式", selection: $coordinator.method) {
                ForEach(JITMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            Button {
                coordinator.showSetup = true
            } label: {
                Label("JIT 设置", systemImage: "bolt.badge.clock")
            }
            if onboarding.available {
                Button {
                    onboarding.rerun()
                } label: {
                    Label("重新运行设置向导", systemImage: "wand.and.stars")
                }
            }
            if coordinator.method == .automatic {
                Text(coordinator.automaticDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if JITShortcutFile.supported, let url = JITShortcutFile.url {
                Button {
                    LogStore.shared.log("[jit-shortcut] add: iCloud link")
                    UIApplication.shared.open(JITShortcutFile.iCloudLink)
                } label: {
                    Label("添加 \(JITNetworkShortcut.name) 快捷指令", systemImage: "plus.square.on.square")
                }
                ShareLink(item: url) {
                    Label("没有互联网连接？添加本地副本", systemImage: "square.and.arrow.up")
                }
            }
            Toggle("\(JITNetworkShortcut.name) 快捷指令", isOn: $shortcut.enabled)
        } header: {
            Text("JIT")
        } footer: {
            Text("当 LocalDevVPN 无法连接到这台设备时，“启用 JIT”会运行你的 \(JITNetworkShortcut.name) 快捷指令：在没有 Wi-Fi 时关闭蜂窝数据并连接 LocalDevVPN，游戏启动后再恢复这两项设置。每次运行都会短暂打开“快捷指令”。")
        }
    }
}

struct JITSetupView: View {
    @ObservedObject private var coordinator = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

    private var pairingLabel: String {
        switch coordinator.pairingSource {
        case .onDevice: return "已在 Madeira 中配对"
        case .imported: return "已导入文件"
        case nil: return "尚未设置"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("方式", selection: $coordinator.method) {
                        ForEach(JITMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    if coordinator.method == .automatic {
                        Text(coordinator.automaticDescription)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("StikDebug",
                                   value: StikJITHelper.isAvailable ? "已安装" : "未检测到")
                    LabeledContent("内置助手",
                                   value: MadeiraBuiltInJIT.isAvailable ? "可用" : "不可用")
                } header: {
                    Text("JIT 方式")
                } footer: {
                    Text("“自动”会在已安装 StikDebug 时使用它。失败后，Madeira 不会擅自切换到其他方式。")
                }

                if coordinator.method != .stikDebug {
                    Section {
                        LabeledContent("配对", value: pairingLabel)
                        if OnDevicePairing.isSupported {
                            Button(coordinator.pairingSource == .onDevice ? "在 Madeira 中重新配对" : "在 Madeira 中配对") {
                                pairing.start()
                            }
                            .disabled(pairing.active)
                            OnDevicePairingPanel()
                        }
                        Button("导入配对文件") { importing = true }
                        Link("如何生成配对文件",
                             destination: URL(string: "https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md")!)
                        Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                    } header: {
                        Text("内置 StikJIT")
                    } footer: {
                        Text(OnDevicePairing.isSupported
                             ? "在 Madeira 中配对，或导入电脑生成的配对文件，连接 LocalDevVPN 后检查设置。配对文件保存在本机钥匙串中。"
                             : "导入这台设备的配对文件，连接 LocalDevVPN 后检查设置。配对文件保存在本机钥匙串中。在 Madeira 中配对需要 iOS 27 或更高版本。")
                    }

                    Section {
                        Button("检查设置") { coordinator.prepareBuiltIn() }
                            .disabled(coordinator.busy || !coordinator.pairingImported)
                        Button("启用 JIT") { coordinator.enableBuiltIn() }
                            .disabled(coordinator.busy || !coordinator.pairingImported)
                        Button("重置开发者磁盘映像", role: .destructive) {
                            coordinator.resetDDI()
                        }.disabled(coordinator.busy)
                    }
                } else {
                    Section {
                        if StikJITHelper.isAvailable {
                            Button("通过 StikDebug 启用 JIT") { coordinator.enable() { _ in } }
                        } else {
                            Link("安装 StikDebug",
                                 destination: URL(string: "https://github.com/StikDebug/StikDebug/releases/latest")!)
                        }
                    } footer: {
                        Text("StikDebug 需要配对文件和已连接的 LocalDevVPN。Madeira 会自动发送所需脚本。")
                    }
                }

                if coordinator.busy {
                    Section { HStack { ProgressView(); Text(coordinator.status ?? "正在处理…") } }
                } else if let error = coordinator.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        if let problem = coordinator.connectionProblem { jitConnectionActions(problem) }
                    }
                } else if let status = coordinator.status {
                    Section { Label(status, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                if let txm = coordinator.txmPresent {
                    Section { LabeledContent("TXM/SPTM", value: txm ? "存在" : "不存在") }
                }
            }
            .navigationTitle("JIT 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { coordinator.showSetup = false; dismiss() }
                }
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.propertyList, .data]) { result in
            if case .success(let url) = result {
                coordinator.importPairingFile(url)
            } else if case .failure(let failure) = result {
                LogStore.shared.log("[jit-built-in] pairing import failed: \(failure.localizedDescription)",
                                    level: .error)
            }
        }
        .onAppear { coordinator.refreshPairingStatus() }
    }
}
