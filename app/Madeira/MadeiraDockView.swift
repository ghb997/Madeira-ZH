// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI

/// State of the Madeira Dock sheet: sign-in, Valve's client components, the
/// installed games and the last Dock result.
@MainActor
final class MadeiraDockModel: ObservableObject {
    static let shared = MadeiraDockModel()

    @Published private(set) var games: [DockGame] = []
    @Published private(set) var clientInstalled = false
    @Published private(set) var preparing = false
    @Published private(set) var progress = ""
    @Published var error: String?
    /// The last Dock launch's outcome, from the host report.
    @Published var status: String?
    /// Opt-in per launch: a 512 MB JIT pool instead of the standard one.
    @Published var compactPool = SteamSignIn.flag("MADEIRA_DOCK_COMPACT_POOL", default: false)
    /// App ID -> number of one-time install programs in the game's Steam install scripts.
    @Published private(set) var installPrograms: [Int: Int] = [:]
    /// App ID -> the game's One-time installs choice (true: Run at next start).
    @Published private(set) var installRunNext: [Int: Bool] = [:]
    /// App ID -> the Record as done / Reset request its next Dock start applies.
    @Published private(set) var installRequest: [Int: DockInstallRequest] = [:]

    private var watch: Task<Void, Never>?

    func refresh() {
        clientInstalled = MadeiraDock.clientInstalled
        let drive = MadeiraDock.drive, prefix = MadeiraDock.prefix
        Task.detached(priority: .userInitiated) {
            let found = MadeiraDock.games(drive: drive)
            var programs: [Int: Int] = [:], runNext: [Int: Bool] = [:], requests: [Int: DockInstallRequest] = [:]
            if DockInstallers.choiceEnabled {
                let ledger = DockInstallLedger.load(prefix: prefix)
                for game in found where game.installed {
                    let count = DockInstallers.programCount(game, drive: drive)
                    if count > 0 { programs[game.id] = count; runNext[game.id] = ledger.runsNext(game.id) }
                    if count > 0, let request = ledger.request(game.id) { requests[game.id] = request }
                }
            }
            let counts = programs, choices = runNext, pendingRequests = requests
            await MainActor.run {
                self.games = found; self.installPrograms = counts; self.installRunNext = choices
                self.installRequest = pendingRequests
            }
        }
    }

    /// The game's One-time installs choice, saved next to the prefix's registry files.
    func setRunsInstallers(_ appID: Int, _ run: Bool) {
        DockInstallers.setRunsNext(appID, run, prefix: MadeiraDock.prefix)
        installRunNext[appID] = run
    }

    /// Saves (nil: cancels) the game's Record as done / Reset request; its next Dock start
    /// applies it while no session runs.
    func setInstallRequest(_ appID: Int, _ request: DockInstallRequest?) {
        DockInstallers.setRequest(appID, request, prefix: MadeiraDock.prefix)
        installRequest[appID] = request
    }

    /// Downloads and unpacks Valve's client components (no Wine session).
    func prepareClient() {
        guard !preparing else { return }
        preparing = true; error = nil; progress = "正在启动…"
        Task { @MainActor in
            do {
                try await SteamRuntimeInstaller.shared.prepare(prefix: MadeiraDock.prefix) { text in
                    await MainActor.run { self.progress = text }
                }
                SteamLog.event("[dock-setup] client components ready")
            } catch {
                self.error = error.localizedDescription
                SteamLog.event("[dock-setup] client components failed")
            }
            preparing = false
            refresh()
        }
    }

    /// Follows the host's report until it records a result, or the session ends
    /// without one, then removes any unconsumed sign-in transfer.
    func watchReport() {
        watch?.cancel()
        let starting = DockInstallers.installsOnly ? "正在安装此游戏的首次运行组件…"
                                                   : "Madeira Dock 正在启动。Valve 客户端将登录并检查许可。"
        let plan = DockInstallers.note
        status = plan.map { $0 + "\n" + starting } ?? starting
        if let plan { LogStore.shared.log("[dock-installers] " + plan) }
        watch = Task { @MainActor in
            var idle = 0, started = false, offered = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let report = MadeiraDock.pollReport()
                DockOffline.observe(report.fields)
                // The game's one-time installs run before the host writes its first field.
                if DockInstallers.script != nil {
                    let progress = DockInstallers.poll(drive: MadeiraDock.drive)
                    if report.fields["probe-start-bits"] == nil, report.result == nil, let progress { status = progress }
                }
                if report.result != nil {
                    if let failure = report.failure {
                        status = failure
                        LogStore.shared.log("[madeira-dock] " + failure, level: .error)
                    } else {
                        status = "Madeira Dock 已正常结束。"
                        LogStore.shared.log("[madeira-dock] host finished (result 0)")
                    }
                    break
                }
                // Steam still counts another session of this account as playing
                // (launch refusal 35); the host asks again for up to three minutes.
                if report.fields["launch-session-wait"] != nil, report.fields["launch-client-error"] == "35" {
                    status = "Steam 提示此账户仍在其他会话中游玩。正在等待 Steam 结束该会话（最多 3 分钟）…"
                }
                // The session starts after the JIT pool is set up; count only once it ran.
                let running = wine_process_is_running() != 0 || wineserver_is_running() != 0
                if running { started = true; idle = 0 } else { idle += 1 }
                if !started && idle >= 150 {
                    status = "Dock 会话未启动。请查看日志。"
                    break
                }
                // madeira-bcd: a program an installer started (a launcher, a helper) can keep a
                // session of one-time installs open after its batch ended. The wineserver writes
                // the registry to disk every 30 s, so 45 s after the batch a restart loses nothing.
                if DockInstallers.installsOnly, running, !offered, let finished = DockInstallers.finishedAt,
                   Date().timeIntervalSince(finished) >= 45 {
                    offered = true
                    let ended = DockInstallers.poll(drive: MadeiraDock.drive) ?? "首次运行组件安装已完成。"
                    status = ended + "\n" + DockInstallers.restartWords
                    LogStore.shared.log("[dock-installers] the session still runs 45 s after the installs ended (a program they started); the restart is offered now")
                    LibraryModel.shared.restartNotice = DockInstallers.restartNotice(ended)
                }
                if started && idle >= 5 {
                    if DockInstallers.installsOnly {
                        // madeira-bcd: a session of one-time installs ends after its batch, and the
                        // game starts in the next app run (DockInstallers.installsOnly). The
                        // wineserver has stopped by now, so the registry is on disk.
                        let ended = DockInstallers.poll(drive: MadeiraDock.drive) ?? "首次运行组件安装已结束。"
                        status = ended + "\n" + DockInstallers.restartWords
                        LogStore.shared.log("[dock-installers] the installs-only session ended; the game starts after Madeira is restarted")
                        LibraryModel.shared.restartNotice = DockInstallers.restartNotice(DockInstallers.poll(drive: MadeiraDock.drive))
                    } else {
                        status = "Madeira Dock 在报告结果前已停止。请导出日志。"
                        LogStore.shared.log("[madeira-dock] session ended without a host result", level: .error)
                    }
                    break
                }
            }
            MadeiraDock.cleanup()
            // The host is done with the sign-in: the app's own Steam connection may come
            // back once no session runs (SteamOwnedLibrary).
            SteamOwnedLibrary.shared.dockEnded()
        }
    }
}

/// Madeira Dock sheet, opened from the developer interface.
struct MadeiraDockView: View {
    @ObservedObject private var dock = MadeiraDockModel.shared
    @ObservedObject private var signIn = SteamSignInModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showSignIn = false
    let start: (DockGame, Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Madeira Dock 通过 Valve 官方 Steam 客户端启动已安装的游戏，但不显示 Steam 桌面窗口。客户端使用你的账户登录，并检查游戏运行许可。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Steam 账户") {
                    if let name = signIn.accountName {
                        LabeledContent("已登录", value: name)
                    } else {
                        Button("登录 Steam") { showSignIn = true }
                    }
                }
                Section {
                    if dock.clientInstalled {
                        Label("Valve 客户端组件已安装", systemImage: "checkmark.circle")
                    } else if dock.preparing {
                        HStack(spacing: 12) { ProgressView(); Text(dock.progress).foregroundStyle(.secondary) }
                    } else {
                        Button("下载 Valve 客户端组件（约 73 MB）") { dock.prepareClient() }
                    }
                } header: { Text("Steam 客户端") } footer: {
                    Text("从 Valve 更新服务器下载，并通过预设的 SHA-256 校验和验证。现有 Steam 文件会保留。")
                }
                Section {
                    if dock.games.isEmpty {
                        Text("drive_c 的 Steam 游戏库中未找到已安装的游戏。").foregroundStyle(.secondary)
                    }
                    ForEach(dock.games) { game in
                        Button { start(game, dock.compactPool); dismiss() } label: {
                            HStack {
                                Text(game.name)
                                Spacer()
                                if !game.installed { Text("尚未安装完成").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(!game.installed || !dock.clientInstalled || !signIn.signedIn)
                    }
                    Toggle("本次启动使用较小的 JIT 内存池（512 MB）", isOn: $dock.compactPool)
                } header: { Text("已安装的游戏") } footer: {
                    Text("Steam 客户端在此 Wine 环境中安装的游戏。仅使用 Steam 默认启动选项。")
                }
                if !dock.installPrograms.isEmpty {
                    Section {
                        ForEach(dock.games.filter { dock.installPrograms[$0.id] != nil }) { game in
                            Picker(game.name, selection: Binding(get: { dock.installRunNext[game.id] ?? true },
                                                                 set: { dock.setRunsInstallers(game.id, $0) })) {
                                Text("下次启动时运行").tag(true)
                                Text("跳过").tag(false)
                            }
                            .pickerStyle(.menu)
                            DockInstallRequestRows(dock: dock, appID: game.id, name: game.name)
                        }
                    } header: { Text("首次运行组件安装") } footer: {
                        Text("这些程序来自游戏的 Steam 安装脚本（例如运行库安装），Steam 桌面客户端会在首次启动前运行。Dock 会在 Valve 客户端启动前运行尚未标记完成的程序，随后选项自动变为“跳过”。“标记为已完成”和“重置”会在下次通过 Dock 启动此游戏时生效。")
                    }
                }
                if let status = dock.status {
                    Section("Dock 状态") { Text(status) }
                }
                if let error = dock.error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Madeira Dock").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .onAppear { dock.refresh(); signIn.refresh() }
            .sheet(isPresented: $showSignIn) { SteamSignInView() }
        }
    }
}

/// A game's One-time installs requests, under its Run at next start / Skip choice: Record as
/// done (an installer that did its work but never closed, so it was never recorded) and
/// Reset (remove what they installed and forget the records, so the installers run again;
/// madeira-bcd: DockReset.swift). Each is saved now and applied at
/// the game's next Dock start, while no session runs (DockInstallers.applyRequest); until
/// then it can be cancelled.
struct DockInstallRequestRows: View {
    @ObservedObject var dock: MadeiraDockModel
    let appID: Int
    let name: String
    @State private var confirmRecord = false
    @State private var confirmReset = false

    var body: some View {
        Group {
            if let request = dock.installRequest[appID] {
                HStack {
                    Text(request == .record ? "下次启动：将首次运行组件安装标记为已完成。"
                         : request == .resetSignOut ? "下次启动：移除首次运行组件及 Rockstar 登录信息，然后重新安装。"
                         : "下次启动：移除首次运行组件，然后重新安装。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { dock.setInstallRequest(appID, nil) }.font(.caption)
                }
            } else {
                Button("标记为已完成…") { confirmRecord = true }
                Button("重置首次运行组件…", role: .destructive) { confirmReset = true }
            }
        }
        .confirmationDialog("将 \(name) 的首次运行组件安装标记为已完成？", isPresented: $confirmRecord, titleVisibility: .visible) {
            Button("标记为已完成") { dock.setInstallRequest(appID, .record) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("适用于已经完成安装但未关闭的安装程序，Madeira 因此未能检测到结束。下次启动时，会将此游戏安装脚本中的程序标记为已完成，与正常结束安装相同，之后不再运行。不会安装或移除任何内容。")
        }
        // madeira-bcd: a reset removes what the installers put in (DockReset.swift), into a backup.
        .confirmationDialog("重置 \(name) 的首次运行组件？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("下次启动时重置", role: .destructive) { dock.setInstallRequest(appID, .reset) }
            Button("重置并退出 Rockstar", role: .destructive) { dock.setInstallRequest(appID, .resetSignOut) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("下次启动时，Madeira 会移除首次运行安装到 Wine 中的组件：Rockstar Games Launcher、Social Club、Visual C++ 2015-2022 运行库（x86 和 x64）及 Vulkan 运行库。该次启动仅会重新运行安装程序，如同新设备；完成后请重启 Madeira 并启动游戏。共用这些组件的游戏（GTA V、Red Dead Redemption 2）也会在下次启动时重新安装。游戏文件和存档会保留。移除的内容会保存在 Madeira 的 Documents/madeira-reset-backup 文件夹中。“退出”还会移除 Rockstar 登录信息。")
        }
    }
}
