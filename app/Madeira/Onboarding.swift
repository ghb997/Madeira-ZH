// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// First-run setup for JIT, Steam sign-in, Madeira Dock and Wine Mono (docs/LIBRARY.md).
// On a new install, and once after an update that raises the setup revision
// (`madeiraOnboardingRevision` in UserDefaults, which iOS removes with the app,
// is below OnboardingRules.revision), the library opens a full-screen setup: welcome, JIT,
// Steam sign-in, Valve's client components for Madeira Dock (only when Dock is
// available), Wine Mono (only when this device has none), done. After an update, only the
// pages added since the revision this device last saw are shown. Every step can be
// skipped. Settings › JIT or Settings › Steam can reopen it in full.
// env.MADEIRA_ONBOARDING = 0 never opens it.
//
// The JIT page offers three ways in (in-app pairing on iOS 27, a pairing
// file from a computer, StikDebug), each with its own numbered steps. It stores
// only the chosen method and, when selected, pairs on this device through
// OnDevicePairing or imports the pairing file through JITCoordinator.
// Sign-in goes through SteamSignIn (the
// token stays in its Keychain store) and the components through
// MadeiraDockModel.prepareClient(), which downloads and verifies files without
// starting Wine. Setup starts no Wine session and changes no JIT pool, engine
// switch or launch configuration.
// Log tag: [onboarding] (no account names, tokens or paths).

// MARK: - Rules (Foundation and MadeiraConfig only; tests/host/check-onboarding.py compiles this part)

enum OnboardingRules {
    /// The setup revision this device last finished or skipped. Raise `revision` in a
    /// release whose setup every existing install should see once.
    static let revisionKey = "madeiraOnboardingRevision"
    /// 1 was the first setup, stored as `madeiraOnboardingDone` (no longer read); 2 adds
    /// Install LocalDevVPN, on-device pairing and the Madeira JIT shortcut; 3 adds the
    /// Wine Mono download.
    static let revision = 3

    /// `env.MADEIRA_ONBOARDING = 0` (madeira.cfg or the environment) never opens
    /// setup and hides "重新运行设置向导". On by default.
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_ONBOARDING") }

    enum Step: String, CaseIterable {
        case welcome, localDevVPN = "localdevvpn", jit, signIn = "sign-in", dockClient = "dock-client",
             wineMono = "wine-mono", done

        /// The revision whose setup first had this page.
        var introduced: Int {
            switch self {
            case .localDevVPN: return 2
            case .wineMono: return 3
            default: return 1
            }
        }
    }

    /// LocalDevVPN comes first when it is not installed (`localDevVPN`): every JIT way
    /// reaches this device through it. JIT is always offered. Sign-in is offered when
    /// Steam sign-in is enabled, or when Madeira Dock is available (Dock needs a
    /// sign-in). Valve's client components are offered only when Dock is available,
    /// Wine Mono only when this device has none (`wineMono`). With `since` (the revision
    /// this device last saw, after an update) only the pages added after it are offered.
    static func steps(signIn: Bool, dock: Bool, localDevVPN: Bool = false, wineMono: Bool = false,
                      since: Int = 0) -> [Step] {
        var list: [Step] = [.welcome]
        if localDevVPN { list.append(.localDevVPN) }
        list.append(.jit)
        if signIn || dock { list.append(.signIn) }
        if dock { list.append(.dockClient) }
        if wineMono { list.append(.wineMono) }
        list.append(.done)
        return since > 0 ? list.filter { $0 == .welcome || $0 == .done || $0.introduced > since } : list
    }

    /// Whether there is anything to set up between the welcome and done pages.
    static func hasSetup(_ steps: [Step]) -> Bool {
        steps.contains(.jit) || steps.contains(.signIn) || steps.contains(.dockClient) || steps.contains(.wineMono)
    }

    /// Whether setup opens by itself when the library appears.
    static func shouldShow(seen: Int, enabled: Bool, steps: [Step]) -> Bool {
        enabled && seen < revision && hasSetup(steps)
    }

    /// The page after `step`, or nil when setup is finished.
    static func next(after step: Step, in steps: [Step]) -> Step? {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    /// "Step n of m" for the pages between welcome and done; nil on those two.
    static func position(of step: Step, in steps: [Step]) -> (number: Int, count: Int)? {
        let middle = steps.filter { $0 != .welcome && $0 != .done }
        guard let index = middle.firstIndex(of: step) else { return nil }
        return (index + 1, middle.count)
    }
}

// MARK: - Setup model

@MainActor final class OnboardingModel: ObservableObject {
    static let shared = OnboardingModel()
    typealias Step = OnboardingRules.Step

    @Published var presented = false
    @Published private(set) var step: Step = .welcome
    /// Considered once per app run, when the library first appears.
    private var considered = false

    static var enabled: Bool { OnboardingRules.enabled }
    /// 0 on a new install, and on one that finished setup before revisions (revision 1).
    static var seen: Int { UserDefaults.standard.integer(forKey: OnboardingRules.revisionKey) }

    /// LocalDevVPN was missing when setup opened, so its page is offered. Fixed for that
    /// run of setup: installing it on the way does not renumber the steps.
    private var offerLocalDevVPN = false
    /// The same for Wine Mono: offered when this device had none when setup opened.
    private var offerWineMono = !WineMonoModel.available
    /// The revision this device had seen when setup opened by itself after an update (only
    /// the pages added since are shown); 0 for a new install and for Run setup again.
    @Published private(set) var since = 0
    var steps: [Step] { steps(since: since) }
    private func steps(since: Int) -> [Step] {
        OnboardingRules.steps(signIn: SteamSignIn.isEnabled, dock: MadeiraDock.enabled, localDevVPN: offerLocalDevVPN,
                              wineMono: offerWineMono, since: since)
    }
    /// Setup can be opened: enabled, and something to set up.
    var available: Bool { Self.enabled && OnboardingRules.hasSetup(steps(since: 0)) }

    private init() {}

    /// The library appeared: open setup once on a new install, and once after an update
    /// that raised the setup revision.
    func presentIfNeeded() {
        guard !considered else { return }
        considered = true
        offerWineMono = !WineMonoModel.available
        guard OnboardingRules.shouldShow(seen: Self.seen, enabled: Self.enabled, steps: steps(since: Self.seen)) else { return }
        open(reason: "revision \(Self.seen)->\(OnboardingRules.revision)", since: Self.seen)
    }

    /// Settings › Steam › Run setup again.
    func rerun() { open(reason: "settings", since: 0) }

    private func open(reason: String, since: Int) {
        // Never over a running session.
        guard available, LibraryModel.shared.current == nil, wine_process_is_running() == 0 else { return }
        offerLocalDevVPN = !LocalDevVPN.isInstalled
        offerWineMono = !WineMonoModel.available
        self.since = since
        LogStore.shared.log("[onboarding] shown reason=\(reason) steps=\(steps.map(\.rawValue).joined(separator: ","))")
        go(.welcome)
        presented = true
    }

    func go(_ next: Step) {
        step = next
        LogStore.shared.log("[onboarding] step=\(next.rawValue)")
    }

    func next() {
        guard let following = OnboardingRules.next(after: step, in: steps) else { finish(); return }
        go(following)
    }

    /// "跳过设置" on the welcome page: done, and not shown again.
    func skip() {
        UserDefaults.standard.set(OnboardingRules.revision, forKey: OnboardingRules.revisionKey)
        LogStore.shared.log("[onboarding] skipped")
        close()
    }

    func finish() {
        UserDefaults.standard.set(OnboardingRules.revision, forKey: OnboardingRules.revisionKey)
        LogStore.shared.log("[onboarding] done")
        close()
    }

    private func close() {
        EndedSessionSurface.hide(reason: "setup-closed")
        presented = false
    }
}

// MARK: - Setup screens

struct OnboardingView: View {
    @ObservedObject private var model = OnboardingModel.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @ObservedObject private var signIn = SteamSignInModel.shared
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var shortcut = JITNetworkShortcut.shared
    @ObservedObject private var mono = WineMonoModel.shared
    @State private var showSignIn = false
    @State private var importingPairingFile = false
    @State private var pairingImportError: String?
    @State private var jitPath: JITSetupPath?
    /// Asked again whenever Madeira comes back to the front (from the App Store, say).
    @State private var localDevVPNInstalled = LocalDevVPN.isInstalled
    @Environment(\.scenePhase) private var scenePhase

    enum JITSetupPath: String {
        case onDevice = "in-app", pairingFile = "pairing-file", stikDebug = "stikdebug"
        /// After a way in is set up (iOS 27): the Madeira JIT shortcut, on its own page.
        case shortcut
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let position = OnboardingRules.position(of: model.step, in: model.steps), position.count > 1 {
                        Text("第 \(position.number) 步，共 \(position.count) 步")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    switch model.step {
                    case .welcome: welcome
                    case .localDevVPN: localDevVPNPage
                    case .jit: jitPage
                    case .signIn: signInPage
                    case .dockClient: dockClientPage
                    case .wineMono: wineMonoPage
                    case .done: donePage
                    }
                }
                .padding(24).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
                .animation(.default, value: jitPath)
                .animation(.default, value: pairing.phase)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showSignIn) { SteamSignInView() }
        .fileImporter(isPresented: $importingPairingFile,
                      allowedContentTypes: [.propertyList, .data]) { result in
            switch result {
            case .success(let url):
                jit.importPairingFile(url)
                if jit.pairingImported {
                    jit.method = .builtIn
                    pairingImportError = nil
                    LogStore.shared.log("[onboarding] JIT method=built-in pairing=imported")
                }
            case .failure(let failure):
                pairingImportError = failure.localizedDescription
                LogStore.shared.log("[onboarding] pairing import failed")
            }
        }
        .onAppear {
            jit.refreshPairingStatus()
            signIn.refresh()
            dock.refresh()
            localDevVPNInstalled = LocalDevVPN.isInstalled
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { localDevVPNInstalled = LocalDevVPN.isInstalled }
        }
    }

    private func header(_ title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(title).font(.title.bold()).accessibilityAddTraits(.isHeader)
        }
    }

    private func primary(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 36)
        }.buttonStyle(.borderedProminent).controlSize(.large)
    }

    private func secondary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).frame(maxWidth: .infinity, minHeight: 44)
    }

    private func point(_ number: Int, _ text: LocalizedStringKey, done: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.subheadline.weight(.bold))
                }
            }
            .frame(width: 26, height: 26)
            .background((done ? Color.green : Color.accentColor).opacity(0.15), in: Circle()).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(done ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? Text("完成") : Text(""))
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 52)).foregroundStyle(.tint).accessibilityHidden(true)
            if model.since > 0 {
                // After an update: only the pages added since this device last ran setup.
                Text("Madeira 新功能").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("自上次设置以来，Madeira 新增了以下设置项目：").font(.title3)
            } else {
                Text("欢迎使用 Madeira").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Madeira 可在你的 \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") 上运行 Windows 游戏。")
                    .font(.title3)
                Text("完成以下可选步骤，即可开始使用：").foregroundStyle(.secondary)
            }
            let pages = model.steps
            let offered: [LocalizedStringKey] =
                (pages.contains(.localDevVPN) ? ["安装 LocalDevVPN，供 Madeira 启用 JIT。"] : [])
                + (pages.contains(.jit) ? ["选择 Madeira 启用 JIT 的方式。"] : [])
                + (pages.contains(.signIn) ? ["在 Madeira 中登录 Steam。"] : [])
                + (pages.contains(.dockClient) ? ["为 Madeira Dock 下载 Valve 的 Steam 客户端组件。"] : [])
                + (pages.contains(.wineMono) ? ["下载 Wine Mono，以支持基于 .NET Framework 的游戏。"] : [])
            ForEach(offered.indices, id: \.self) { index in point(index + 1, offered[index]) }
            primary("开始设置", symbol: "arrow.right") { model.next() }.padding(.top, 8)
            secondary("跳过设置") { model.skip() }
        }
    }

    /// LocalDevVPN first, offered only when it was missing: every JIT way reaches this
    /// device through it. LocalDevVPN.isInstalled asks iOS whether an app handles
    /// localdevvpn:// (canOpenURL; the scheme is declared in Info.plist), so nothing opens.
    private var localDevVPNPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("安装 LocalDevVPN", symbol: "network")
            Text("Madeira 通过免费的 LocalDevVPN 应用启用 JIT，它能让 Madeira 通过网络连接到这台 \(device)。请先从 App Store 安装，然后返回。")
                .fixedSize(horizontal: false, vertical: true)
            if localDevVPNInstalled {
                Label("已安装 LocalDevVPN", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                primary("继续", symbol: "arrow.right") { model.next() }
            } else {
                primary("获取 LocalDevVPN", symbol: "arrow.down.app") {
                    LogStore.shared.log("[onboarding] LocalDevVPN app-store")
                    UIApplication.shared.open(LocalDevVPN.appStore)
                }
                secondary("稍后再设置") { model.next() }
            }
        }
    }

    // JIT: pick one of three ways in, then follow its numbered steps.

    private var pairedOnDevice: Bool { jit.pairingImported && jit.pairingSource == .onDevice }
    private var fileImported: Bool { jit.pairingImported && jit.pairingSource == .imported }

    @ViewBuilder private var jitPage: some View {
        switch jitPath {
        case nil: jitChoices
        case .onDevice: onDeviceGuide
        case .pairingFile: pairingFileGuide
        case .stikDebug: stikDebugGuide
        case .shortcut: shortcutPage
        }
    }

    private var jitChoices: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("设置 JIT", symbol: "bolt.fill")
            Text("JIT 让 Madeira 能够运行 Windows 代码。请选择这台 \(device) 启用 JIT 的方式。")
            VStack(spacing: 12) {
                jitChoice("应用内配对", symbol: "iphone.radiowaves.left.and.right",
                          detail: !OnDevicePairing.isSupported ? "需要 iOS 27 或更高版本。"
                              : pairedOnDevice ? "已在这台 \(device) 上配对。"
                              : "在系统“设置”中将这台 \(device) 与 Madeira 配对，无需电脑。",
                          done: pairedOnDevice, enabled: OnDevicePairing.isSupported) { choose(.onDevice) }
                jitChoice("在应用内使用配对文件", symbol: "doc.badge.plus",
                          detail: fileImported ? "已导入配对文件。" : "使用在电脑上生成的配对文件。",
                          done: fileImported) { choose(.pairingFile) }
                jitChoice("StikDebug", symbol: "ant",
                          detail: "使用 StikDebug 应用启用 JIT。",
                          done: jit.method == .stikDebug) { choose(.stikDebug) }
            }
            secondary("稍后再设置") { model.next() }
        }
    }

    private var onDeviceGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("在这台 \(device) 上配对", symbol: "iphone.radiowaves.left.and.right")
            VStack(alignment: .leading, spacing: 14) {
                point(1, "打开 Wi-Fi，然后轻点**开始配对**并允许访问本地网络。",
                      done: pairing.phase != .idle || pairedOnDevice)
                point(2, "打开系统“设置”›“隐私与安全性”›“开发者模式”，向下滚动并轻点**与 \(OnDevicePairing.hostName) 配对**。",
                      done: pairing.isShowingPin || pairedOnDevice)
                point(3, "输入 Madeira 显示的配对码。屏幕顶部横幅和通知中也会显示此代码。",
                      done: pairedOnDevice)
            }
            if pairedOnDevice {
                Label("已在这台 \(device) 上配对", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                vpnNote
                primary("继续", symbol: "arrow.right") { useBuiltIn() }
                secondary("重新配对") { startPairing() }
            } else {
                primary("开始配对", symbol: "dot.radiowaves.left.and.right") { startPairing() }
                    .disabled(pairing.active)
                OnDevicePairingPanel()
            }
            secondary("返回选项") { leaveGuide() }
        }
    }

    private var pairingFileGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("使用配对文件", symbol: "doc.badge.plus")
            VStack(alignment: .leading, spacing: 14) {
                point(1, "在电脑上按照 [StikDebug 配对文件指南](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md)，为这台 \(device) 生成配对文件。",
                      done: fileImported)
                point(2, "将文件保存到“文件”应用，或通过隔空投送发送到这台 \(device)。", done: fileImported)
                point(3, "轻点**选择配对文件**并选取该文件。", done: fileImported)
            }
            Label("配对文件保存在这台 \(device) 的钥匙串中。", systemImage: "lock.fill")
                .font(.subheadline).foregroundStyle(.secondary)
            if fileImported {
                Label("已导入配对文件", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                vpnNote
                primary("继续", symbol: "arrow.right") { useBuiltIn() }
                secondary("选择其他配对文件") { importPairingFile() }
            } else {
                primary("选择配对文件", symbol: "folder") { importPairingFile() }
            }
            if let error = pairingImportError ?? jit.error {
                Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            secondary("返回选项") { leaveGuide() }
        }
    }

    private var stikDebugGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("使用 StikDebug", symbol: "ant")
            VStack(alignment: .leading, spacing: 14) {
                point(1, "安装 [StikDebug](https://github.com/StikDebug/StikDebug/releases/latest)，并将这台 \(device) 的配对文件导入其中。")
                point(2, "安装并连接 [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)。")
                point(3, "开始游戏时，Madeira 会打开 StikDebug 以启用 JIT，然后自动返回。")
            }
            primary("使用 StikDebug", symbol: "arrow.right") {
                jit.method = .stikDebug
                LogStore.shared.log("[onboarding] JIT method=StikDebug")
                finishJIT()
            }
            secondary("返回选项") { leaveGuide() }
        }
    }

    /// Only on iOS 26: from iOS 27 the Connect automatically page that follows the guide
    /// covers LocalDevVPN.
    @ViewBuilder private var vpnNote: some View {
        if !JITShortcutFile.supported { vpnNoteLabel }
    }

    private var vpnNoteLabel: some View {
        Label {
            Text("开始游戏前，请先连接 [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)。Madeira 将通过它启用 JIT。")
        } icon: {
            Image(systemName: "network")
        }
        .font(.subheadline).foregroundStyle(.secondary)
    }

    private func jitChoice(_ title: String, symbol: String, detail: String, done: Bool, enabled: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.5)
    }

    private func choose(_ way: JITSetupPath) {
        pairingImportError = nil
        LogStore.shared.log("[onboarding] JIT way=\(way.rawValue)")
        jitPath = way
    }

    private func leaveGuide() {
        if pairing.active { pairing.cancel() }
        jitPath = nil
    }

    private func startPairing() {
        pairingImportError = nil
        LogStore.shared.log("[onboarding] JIT in-app pairing started")
        pairing.start()
    }

    private func importPairingFile() {
        pairingImportError = nil
        importingPairingFile = true
    }

    private func useBuiltIn() {
        jit.method = .builtIn
        LogStore.shared.log("[onboarding] JIT method=built-in")
        finishJIT()
    }

    /// A way in is set up: the Madeira JIT shortcut's page on iOS 27, else the next step.
    private func finishJIT() {
        if JITShortcutFile.supported, JITShortcutFile.url != nil {
            jitPath = .shortcut
        } else {
            model.next()
        }
    }

    /// The Madeira JIT shortcut (iOS 27; JITShortcutFile), on its own page so the JIT
    /// guides fit on one screen. Add it from its iCloud link (straight to Add Shortcut)
    /// or, with no internet connection, the local copy through the share sheet; then turn
    /// it on.
    /// It drives LocalDevVPN with LocalDevVPN's own Shortcuts action.
    private var shortcutPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("自动连接", symbol: "bolt.horizontal.circle")
            Text("使用 \(JITNetworkShortcut.name) 快捷指令后，“启用 JIT”会自动连接 LocalDevVPN，在没有 Wi-Fi 时暂时关闭蜂窝数据，并在游戏启动后恢复这两项设置及原先使用的 VPN。")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                point(1, "安装 [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)。",
                      done: LocalDevVPN.isInstalled)
                point(2, "轻点**添加快捷指令**，然后在“快捷指令”应用中轻点**添加快捷指令**。")
                point(3, "打开**用于启用 JIT**。", done: shortcut.enabled)
            }
            Button {
                LogStore.shared.log("[jit-shortcut] add: iCloud link")
                UIApplication.shared.open(JITShortcutFile.iCloudLink)
            } label: {
                Label("添加快捷指令", systemImage: "plus.square.on.square")
                    .fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered).controlSize(.large)
            if let url = JITShortcutFile.url {
                ShareLink(item: url) {
                    Text("没有互联网连接？添加本地副本，然后在弹出的共享菜单中选择“快捷指令”。")
                        .font(.footnote).frame(maxWidth: .infinity)
                }
            }
            Toggle("用于启用 JIT", isOn: $shortcut.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            primary("继续", symbol: "arrow.right") {
                LogStore.shared.log("[onboarding] JIT shortcut on=\(shortcut.enabled ? 1 : 0)")
                model.next()
            }
        }
    }

    private var signInPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("登录 Steam", symbol: "person.crop.circle.badge.checkmark")
            Text(model.steps.contains(.dockClient)
                 ? "通过 Madeira Dock 启动游戏时，Madeira 会将此登录信息交给 Valve 官方 Steam 客户端，由其登录并验证你的游戏许可。"
                 : "Madeira 会保存 Steam 登录状态，以便通过你的账号启动 Steam 游戏。")
            VStack(alignment: .leading, spacing: 10) {
                Label("密码只会发送给 Steam，且不会被保存。", systemImage: "lock.fill")
                Label("登录信息将保存在本机钥匙串中，直到你退出登录。", systemImage: "iphone")
            }.font(.subheadline).foregroundStyle(.secondary)
            if let name = signIn.accountName {
                Label("已登录：\(name)", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                primary("继续", symbol: "arrow.right") { model.next() }
                secondary("使用其他账号") {
                    LogStore.shared.log("[onboarding] sign-in replaced")
                    signIn.signOut(); showSignIn = true
                }
            } else {
                primary("登录 Steam", symbol: "person.crop.circle") { showSignIn = true }
                secondary("稍后设置") { model.next() }
            }
        }
    }

    private var dockClientPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("准备 Madeira Dock", symbol: "shippingbox")
            Text("Madeira Dock 通过 Valve 官方 Steam 客户端启动已安装的 Steam 游戏，无需显示 Steam 桌面窗口。它需要相应的客户端组件，Madeira 将从 Valve 下载这些组件。")
            if dock.clientInstalled {
                Label("已安装 Valve 客户端组件。", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                primary("继续", symbol: "arrow.right") { model.next() }
            } else {
                Text("将从 Valve 更新服务器下载约 73 MB，并使用预设 SHA-256 校验值验证。此过程无需运行 Windows 会话。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if dock.preparing {
                    HStack(spacing: 12) { ProgressView(); Text(dock.progress).foregroundStyle(.secondary) }
                } else {
                    if let error = dock.error {
                        Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    primary(dock.error == nil ? "下载组件" : "重试", symbol: "arrow.down.circle.fill") {
                        LogStore.shared.log("[onboarding] components download")
                        dock.prepareClient()
                    }
                }
                // A running download continues; Settings › Steam › Madeira Dock shows it.
                secondary("稍后设置") { model.next() }
            }
        }
    }

    /// Wine Mono, offered when this device has none: games built on .NET Framework need it.
    /// The download continues if the page is left; Settings › .NET Framework shows it.
    private var wineMonoPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("添加 .NET Framework 支持", symbol: "shippingbox.and.arrow.backward")
            Text("部分 Windows 游戏基于微软的 .NET Framework 开发。Madeira 使用 Wine 项目的开源 .NET 运行时 Wine Mono 运行这些游戏。")
            if mono.installed {
                Label("已安装 Wine Mono。", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                primary("继续", symbol: "arrow.right") { model.next() }
            } else {
                Text("Madeira 将从 WineHQ 下载约 42 MB，安装后占用约 130 MB。大多数游戏无需此组件；你也可以稍后在设置中添加。")
                    .font(.subheadline).foregroundStyle(.secondary)
                switch mono.phase {
                case .downloading(let f), .installing(let f):
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: f)
                        Text(mono.status).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                case .idle:
                    if let error = mono.error {
                        Label(error, systemImage: "exclamationmark.circle.fill").foregroundStyle(.red)
                    }
                    primary(mono.error == nil ? "下载 Wine Mono" : "重试", symbol: "arrow.down.circle.fill") {
                        LogStore.shared.log("[onboarding] Wine Mono download")
                        mono.install()
                    }
                }
                secondary("稍后设置") { model.next() }
            }
        }
    }

    private var donePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("设置完成", symbol: "checkmark.seal.fill")
            if model.steps.contains(.jit) {
                Text("你可以在“设置”›“JIT”中更改 JIT 方式或导入配对文件。")
            }
            if model.steps.contains(.dockClient) {
                Text("“设置”›“Steam”›“Madeira Dock”会列出并启动 Madeira 的 drive_c 中已安装的 Steam 游戏。")
            }
            if model.steps.contains(.wineMono) {
                Text("在“设置”›“.NET Framework”中可以下载或移除 Wine Mono。")
            }
            Text("你可以在“设置”›“JIT”或“设置”›“Steam”中重新运行此设置向导。").foregroundStyle(.secondary)
            primary("前往游戏库", symbol: "square.grid.2x2.fill") { model.finish() }
        }
    }
}

// MARK: - Settings › Steam

/// The library's Steam settings: the signed-in account, Sign in / Sign out
/// (SteamSignIn; the token stays in its Keychain store), Madeira Dock's sheet
/// and "重新运行设置向导".
struct SteamSettingsSection: View {
    /// Opens Steam sign-in or Madeira Dock. LibraryView presents the sheet from the
    /// Settings Form: a sheet attached to this section closed again as soon as it
    /// slid up whenever the Form rebuilt its rows.
    let open: (SettingsSheet) -> Void
    @ObservedObject private var signIn = SteamSignInModel.shared
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var onboarding = OnboardingModel.shared
    @State private var confirmSignOut = false

    /// Shown when Steam sign-in or Madeira Dock is available.
    static var shown: Bool { SteamSignIn.isEnabled || MadeiraDock.enabled }

    var body: some View {
        Section {
            if let name = signIn.accountName {
                LabeledContent("当前账号", value: name)
                Button("退出 Steam 登录", role: .destructive) { confirmSignOut = true }
            } else {
                Button { open(.steamSignIn) } label: { Label("登录 Steam", systemImage: "person.crop.circle.badge.plus") }
            }
            if MadeiraDock.enabled {
                Button { open(.dock) } label: { Label("Madeira Dock", systemImage: "shippingbox") }
                if let status = dock.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if onboarding.available {
                Button { onboarding.rerun() } label: { Label("重新运行设置向导", systemImage: "wand.and.stars") }
            }
        } header: {
            Text("Steam")
        } footer: {
            Text("Madeira 将 Steam 登录令牌保存在本机钥匙串中，仅供这台设备使用。退出登录后会移除该令牌。")
        }
        .confirmationDialog("退出 Steam 登录？", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { signIn.signOut() }
        }
        .onAppear { signIn.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: SteamSignIn.didChange)) { _ in signIn.refresh() }
    }
}

// MARK: - Madeira Dock in the library

extension LibraryEntry {
    static let dockSessionID = UUID(uuidString: "5D0C4A3E-2B7F-4C61-9E0A-6B1D2F3C4E5A")!

    /// A Dock start from the library runs as a library session (full-screen
    /// view, starting screen, in-game menu, one session per run) with this
    /// entry. It is a desktop session: explorer's virtual desktop runs the
    /// host. It is never saved to the library.
    static func dockSession(title: String, width: Int, height: Int) -> LibraryEntry {
        var entry = LibraryEntry(title: title.isEmpty ? "Madeira Dock" : title, relativePath: "windows/system32/explorer.exe", bits: 64)
        entry.id = dockSessionID; entry.desktop = true; entry.resolution = "\(width)x\(height)"
        entry.graphicsAPI = "Madeira Dock"
        return entry
    }
}
