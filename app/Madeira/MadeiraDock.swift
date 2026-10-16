// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import Darwin
import Network

/// JIT pool size of a Dock session. A Dock session runs no desktop Steam
/// client (no Chromium helper fan-out), so it can live with a smaller pool.
/// Opt-in per launch (the Dock sheet's toggle, default from
/// `env.MADEIRA_DOCK_COMPACT_POOL`, off unless set to 1). It never applies
/// outside a Dock launch, and an explicit madeira.cfg `pool` still wins
/// because the caller applies that afterwards.
enum DockPerformancePolicy {
    static let compactPoolMB = 512

    static func sessionPoolMB(standard: Int, dock: Bool, compact: Bool) -> Int {
        dock && compact ? min(standard, compactPoolMB) : standard
    }
}

enum DockError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// A game Steam's client has installed in the prefix, read from its
/// `steamapps/appmanifest_<appid>.acf`.
struct DockGame: Identifiable, Equatable, Sendable {
    let id: Int                 // App ID
    let name: String
    let installDir: String      // one folder name under <library>/common
    let library: String         // drive-relative steamapps folder
    let installed: Bool         // StateFlags has "fully installed"
    let customExecutables: Bool // the install record lists per-user executables (CheckGuid)

    /// Windows path of the game's folder, which Dock requires Valve's client to resolve to.
    var windowsInstallPath: String {
        "C:\\" + (library + "/common/" + installDir).replacingOccurrences(of: "/", with: "\\")
    }
}

/// Madeira Dock: a small headless host (madeira-dock, built by
/// build/madeira-dock/build.sh into arm64ec-windows/dockhost.exe) that loads
/// Valve's genuine Windows Steam client inside the Wine session, signs in
/// with the user's own refresh token and asks the client to start an
/// installed game with Valve's own LaunchApp. Valve's client performs the
/// online authentication and licence checks; the game and its DRM are
/// untouched. The host drives undocumented client interfaces and supports
/// only client builds it has verified by SHA-256; anything else fails closed
/// with a report code.
///
/// The app side is this contract: environment variables, a one-use sign-in
/// transfer file and a numeric report file (C:\madeira-dock.txt).
enum MadeiraDock {
    /// `env.MADEIRA_DOCK = 0` hides Dock. Without a built dockhost.exe it is hidden too.
    static var enabled: Bool { SteamSignIn.flag("MADEIRA_DOCK", default: true) && bundled }
    static var bundled: Bool {
        Bundle.main.url(forResource: "dockhost", withExtension: "exe", subdirectory: "arm64ec-windows") != nil
    }
    static let executable = "C:\\windows\\system32\\dockhost.exe"

    static var prefix: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("wine")
    }
    static var drive: URL { prefix.appendingPathComponent("drive_c") }
    static var clientRoot: URL { drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot, isDirectory: true) }
    static var clientInstalled: Bool {
        FileManager.default.fileExists(atPath: clientRoot.appendingPathComponent("steamclient64.dll").path)
    }

    // MARK: Installed games

    static func validAppID(_ value: Int) -> Bool { value > 0 && UInt64(value) < UInt64(UInt32.max) }

    /// One folder name: no separators, drive letters, parent references or control characters.
    static func validFolderName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 240 && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains(":") && !name.contains("\"") &&
            !name.unicodeScalars.contains { $0.value < 32 } && !name.hasSuffix(" ") && !name.hasSuffix(".")
    }

    /// The game an app manifest describes, or nil when it is not one Dock can start.
    static func game(manifest data: Data, library: String) -> DockGame? {
        guard data.count <= 1 << 20, var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], let appID = state["appid"]?.string.flatMap({ Int($0) }), validAppID(appID),
              let folder = state["installdir"]?.string, validFolderName(folder) else { return nil }
        let flags = state["StateFlags"]?.string.flatMap { UInt32($0) } ?? 0
        let name = state["name"]?.string.map { String($0.prefix(200)) } ?? ""
        return DockGame(id: appID, name: name.isEmpty ? "应用 \(appID)" : name, installDir: folder, library: library,
                        installed: flags & 4 != 0, customExecutables: !(state["CheckGuid"]?.fields.isEmpty ?? true))
    }

    /// A record's depots: the ones it lends from each owner app (`SharedDepots`, depot -> owner)
    /// and the ones installed for the app itself (`InstalledDepots`).
    static func depots(manifest data: Data) -> (lent: [Int: Set<String>], installed: Set<String>) {
        guard data.count <= 1 << 20, var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], let appID = state["appid"]?.string.flatMap({ Int($0) }) else { return ([:], []) }
        var lent: [Int: Set<String>] = [:]
        for (depot, owner) in (state["SharedDepots"]?.fields ?? [:]).prefix(64) {
            guard let ownerID = owner.string.flatMap({ Int($0) }), validAppID(ownerID), ownerID != appID else { continue }
            lent[ownerID, default: []].insert(depot)
        }
        return (lent, Set((state["InstalledDepots"]?.fields ?? [:]).keys.prefix(256)))
    }

    /// Installed games in the client's own library (`<client>/steamapps`) and the other
    /// libraries on C: that its `libraryfolders.vdf` lists. Read-only.
    static func games(drive: URL) -> [DockGame] {
        let fm = FileManager.default
        let clientLibrary = SteamRuntimeFiles.relativeRoot + "/steamapps"
        var libraries = [clientLibrary]
        if let data = try? Data(contentsOf: drive.appendingPathComponent(clientLibrary + "/libraryfolders.vdf")),
           data.count <= 1 << 20, var parser = try? SteamKeyValues(data), let root = try? parser.read() {
            for (_, entry) in (root["libraryfolders"]?.fields ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let path = entry["path"]?.string?.replacingOccurrences(of: "\\\\", with: "\\"),
                      let relative = libraryRelative(path) else { continue }
                if !libraries.contains(where: { $0.caseInsensitiveCompare(relative) == .orderedSame }) { libraries.append(relative) }
            }
        }
        var result: [DockGame] = []
        // Apps that only lend depots to another install ("Shared Only", e.g. GTA V
        // Enhanced's RGL/SC 1899670) have a record but nothing to start. A game that
        // lends depots but has its own installed too (a base game whose depots its
        // expansions share) stays: the same test as the uninstall (SteamInstall.swift).
        var lent: [Int: Set<String>] = [:], installed: [Int: Set<String>] = [:]
        for library in libraries.prefix(16) {
            let folder = drive.appendingPathComponent(library, isDirectory: true)
            guard folder.resolvingSymlinksInPath().path.hasPrefix(drive.resolvingSymlinksInPath().path + "/"),
                  let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for file in names.sorted().prefix(2000) where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { continue }
                let held = depots(manifest: data)
                lent.merge(held.lent) { $0.union($1) }
                guard let game = game(manifest: data, library: library),
                      !result.contains(where: { $0.id == game.id }) else { continue }
                installed[game.id] = held.installed
                result.append(game)
            }
        }
        result.removeAll { game in lent[game.id].map { installed[game.id, default: []].isSubset(of: $0) } ?? false }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// "C:\\Games\\SteamLibrary" -> "Games/SteamLibrary/steamapps" (C: only).
    static func libraryRelative(_ windowsPath: String) -> String? {
        let path = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard path.lowercased().hasPrefix("c:/") else { return nil }
        let parts = path.dropFirst(3).split(separator: "/").map(String.init)
        guard !parts.isEmpty, parts.count <= 16, parts.allSatisfy(validFolderName) else { return nil }
        return (parts + ["steamapps"]).joined(separator: "/")
    }

    /// Everything a launch needs, checked before any sign-in is handed over.
    static func validate(_ game: DockGame, drive: URL, bundled: Bool = MadeiraDock.bundled) throws {
        guard bundled else { throw DockError.message("此应用未内置 Madeira Dock。请运行 build/madeira-dock/build.sh 构建。") }
        guard validAppID(game.id), validFolderName(game.installDir) else {
            throw DockError.message("此游戏的 Steam 安装记录无效。")
        }
        guard FileManager.default.fileExists(atPath: drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot + "/steamclient64.dll").path) else {
            throw DockError.message("缺少 Steam 客户端文件。请先下载 Valve 客户端组件。")
        }
        var isFolder: ObjCBool = false
        guard game.installed,
              FileManager.default.fileExists(atPath: drive.appendingPathComponent(game.library + "/common/" + game.installDir).path, isDirectory: &isFolder),
              isFolder.boolValue else {
            throw DockError.message("Steam 未将此游戏标记为安装完成。")
        }
    }

    // MARK: Sign-in transfer

    /// Tokens stay in Keychain except for this bounded one-use transfer. The
    /// payload is not an ownership claim: Valve authenticates it in the guest.
    static func envelope(account: String, token: String, steamID: UInt64, appID: Int) throws -> Data {
        let name = Array(account.utf8), secret = Array(token.utf8)
        guard (1...64).contains(name.count), (1...8192).contains(secret.count),
              name.allSatisfy({ (33...126).contains($0) }),
              secret.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }),
              steamID >> 56 == 1, (steamID >> 52) & 15 == 1, (steamID >> 32) & 0xfffff == 1,
              steamID & 0xffffffff != 0, validAppID(appID) else {
            throw DockError.message("无法将 Steam 登录信息传递给 Dock。请在 Madeira 中重新登录 Steam。")
        }
        var data = Data("MDOCK001".utf8)
        func append(_ value: UInt64, bytes: Int) {
            for i in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        }
        append(steamID, bytes: 8); append(UInt64(appID), bytes: 4)
        append(UInt64(name.count), bytes: 2); append(UInt64(secret.count), bytes: 2)
        data.append(contentsOf: name); data.append(contentsOf: secret)
        return data
    }

    /// The JWT subject selects the account; it is deliberately not treated as
    /// authenticated identity. Only Valve accepting the token can establish it.
    static func subject(_ token: String) throws -> UInt64 {
        guard token.utf8.count <= 8192 else { throw DockError.message("Steam 登录信息过大。") }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw DockError.message("Steam 登录信息需要更新。") }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["sub"] as? String, let id = UInt64(text) else {
            throw DockError.message("Steam 登录信息需要更新。")
        }
        return id
    }

    /// The seeded prefix has C: but no guaranteed Z: mapping. Wine's Unix
    /// namespace reaches the protected native file without a drive mapping
    /// and without moving the transfer into the user-visible Documents folder.
    static func handoffGuestPath(_ url: URL, unixNamespace: Bool = true) -> String {
        (unixNamespace ? "\\\\?\\unix" : "Z:") + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    // MARK: Report

    /// The host's report: a bounded set of numeric fields, never arbitrary guest text.
    struct Report {
        var fields: [String: String] = [:]
        var result: Int? { fields["probe-result"].flatMap(Int.init) }
        var failure: String? {
            guard let result, result != 0 else { return nil }
            if result == 30 {
                if fields["session-unsupported-client"] == "1" || fields["session-user-method-mismatch"] != nil {
                    return "Madeira Dock 不支持此 Steam 客户端版本。Dock 仅支持已验证的版本；日志中包含客户端指纹和未通过的检查。"
                }
                return "Madeira Dock 无法初始化 Steam 会话（代码 30）。请导出日志以确定未通过的检查。"
            }
            // The host waits 90 s after sign-in for Valve's client to count the game
            // among the account's subscriptions (madeira-dock src/session.c).
            if result == 34 {
                return fields["session-authenticated-online"] == "1"
                    ? "Steam 已登录，但未及时确认此游戏的许可。请先导出日志再重试。"
                    : "Steam 登录未完成。请检查网络连接后重试。"
            }
            if result == 35 { return "Steam 未确认当前登录账户拥有此游戏的许可。" }
            // Offline start (madeira-dock docs/OFFLINE.md): Valve's client decides.
            if result == 50 {
                return fields["session-offline-abi"] == "0"
                    ? "当前无网络连接，Madeira Dock 无法离线启动此版本的 Steam 客户端。请联网后重试。"
                    : "当前无网络连接，Steam 也未保存此账户的离线登录信息。请联网启动一次游戏，此后可在离线登录过期前离线启动。"
            }
            if result == 51 { return "当前无网络连接，Steam 拒绝离线登录。请联网启动一次游戏。如果再次出现，请导出日志。" }
            if result == 52 { return "Steam 已离线登录，但保存的许可列表中没有此游戏。请联网启动此游戏一次，之后即可离线游玩。" }
            if result == 37 {
                if fields["session-native-handoff-app-mismatch"] == "1" {
                    return "Madeira Dock 收到了其他启动会话的登录信息。请关闭会话后重试。"
                }
                return "Madeira Dock 无法读取一次性 Steam 登录传递信息。Steam 尚未检查登录。请先导出日志再重试。"
            }
            // Valve's client could not prepare the game's per-user executable.
            if result == 49 {
                switch fields["ceg-result"].flatMap(Int.init) {
                case -1: return "Steam 准备此游戏可执行文件超时。请检查网络连接后重试。"
                case 0: return "Steam 未开始准备此游戏的可执行文件。请在 Steam 中验证游戏文件后重试。"
                case 10: return "Steam 正忙于处理此游戏（正在更新或运行）。请稍后重试。"
                case -4: return "无法启动 Steam 的 Windows 服务管理器，因此 Steam 无法准备此游戏的可执行文件。"
                case -5: return "Madeira 的 Windows 环境中未安装 Steam 的 Windows 服务，因此无法准备此游戏的可执行文件。"
                default: return "Steam 无法为你的账户准备此游戏的可执行文件（代码 \(fields["ceg-result"] ?? "?")）。"
                }
            }
            if result == 45 || result == 48, fields["launch-option-missing"] != nil || fields["launch-option-invalid"] != nil {
                return "Steam 拒绝了此游戏的启动选项。请刷新 Steam 游戏库后重试。"
            }
            if result == 45 || result == 48, let error = fields["launch-client-error"].flatMap(Int.init),
               (22...23).contains(error), fields["launch-config-wait"] != nil {
                return "Steam 登录后未能完成加载此游戏的配置。请等待一分钟后重新启动游戏。"
            }
            // The host asked again for up to three minutes while Steam still counted
            // another session of this account as playing (refusal 35); it still did.
            if result == 45 || result == 48, fields["launch-client-error"] == "35", fields["launch-session-wait"] != nil {
                return "Steam 仍提示此账户正在其他会话中游玩。请关闭其他设备上的游戏（或在关闭会话后等待几分钟），然后重新启动。"
            }
            if result == 45 || result == 48, let error = fields["launch-client-error"].flatMap(Int.init),
               let reason = Self.launchRefusal(error, waited: result == 48) {
                return reason
            }
            return "Madeira Dock 无法完成 Steam 启动（代码 \(result)）。请先导出日志再重试。"
        }

        /// Valve's own launch refusal (EAppUpdateError) in words. Numbers only
        /// come from the host report; nothing here changes what Steam decided.
        static func launchRefusal(_ error: Int, waited: Bool) -> String? {
            switch error {
            case 5: return "Steam 未确认当前登录账户拥有此游戏的许可。"
            case 6, 21: return "Steam 无法连接服务器来启动此游戏。请检查网络连接后重试。"
            case 16: return "Steam 提示此游戏已在运行。请先关闭游戏再重试。"
            case 17, 19, 20:
                return waited
                    ? "Steam 未能完成安装此游戏所需的内容。请稍后重试。"
                    : "Steam 需要先安装或更新此游戏依赖的内容。请重新启动游戏，让 Madeira Dock 等待 Steam 完成。"
            case 18: return "Steam 未识别到此游戏已安装。"
            case 28: return "Steam 找不到游戏的可执行文件。"
            // Steam's CreateProcess for the game failed: Madeira could not load the program.
            case 29: return "Steam 已启动此游戏的程序，但 Madeira 无法加载（Steam 报告平台无效）。请导出日志，其中包含具体原因。"
            case 22, 23, 24: return "Steam 无法读取此游戏的配置。请重试。"
            case 25: return "Steam 提示此游戏尚未发行。"
            case 26: return "Steam 提示此游戏在你所在地区不可用。"
            case 35: return "Steam 提示此账户正在其他会话中游玩。请关闭其他设备上的游戏后重新启动。"
            default: return nil
            }
        }
    }

    static let reportAllowed: Set<String> = ["probe-start-bits", "client-machine", "client-pe-timestamp",
        "load-client-begin", "load-client-error", "public-client021-present", "engine005-present",
        "engine-factory-result", "session-client-adapter", "session-unsupported-client", "session-user-method-mismatch",
        "session-private-abi-verified", "session-login-disabled", "session-native-handoff-invalid",
        "session-native-handoff-app-mismatch", "session-handoff-stage", "session-handoff-error",
        "session-account-input-invalid", "session-app-input-invalid",
        "session-native-token-submitted", "session-logon-start-result", "session-connection-result",
        "session-authenticated-online", "session-requested-app-entitled", "session-subscription-count",
        "session-requested-app-listed", "session-auth-test-result",
        "session-online-subscription-count", "session-online-app-zero-query", "session-online-callback-id",
        "session-timeout-subscription-count", "session-timeout-app-listed", "session-timeout-still-online",
        "session-online-blip", "session-online-blips", "session-online-lost", "session-entitlement-source",
        "session-offline-abi", "session-offline-requested", "session-offline-can", "session-offline-logon-result",
        "session-offline-logon-retry", "session-offline-logon-state", "session-offline-callback-id",
        "session-offline-entitled", "session-offline-listed", "session-offline-timeout-state",
        "session-offline-fallback", "session-offline-ready",
        "launch-client-error", "launch-option-index", "launch-option-invalid", "launch-option-missing",
        "launch-update-wait", "launch-update-retry", "launch-update-ready",
        "launch-config-wait", "launch-config-gave-up", "launch-session-wait", "launch-session-gave-up",
        "ceg-request", "ceg-request-result", "ceg-request-busy", "ceg-server-result", "ceg-job-result",
        "ceg-finished-jobs", "ceg-result", "ceg-disabled", "ceg-unsupported-client",
        "ceg-scm", "ceg-scm-started", "ceg-scm-error", "ceg-service-registered", "ceg-service-install", "ceg-service-stop", "ceg-scm-stopped",
        "game-scm", "game-scm-timeout", "launch-keep-alive",
        "shutdown-begin", "shutdown-complete", "probe-result"]
    /// The host's report rounds (madeira-dock src/main.c).
    static let reportRounds: Set<String> = ["ml1820", "ml1830", "ml1860", "ml1870", "ml1970", "ml1990", "ml2000", "ml2011", "ml2015", "ml2016"]

    static func parseReport(_ data: Data) -> Report {
        guard data.count <= 32768, let text = String(data: data, encoding: .utf8) else { return Report() }
        var report = Report()
        // Ignore a partial final line until the writer completes and flushes it.
        for line in text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "[steam-host]", reportRounds.contains(String(parts[1])) else { continue }
            let field = parts[2].trimmingCharacters(in: .newlines).split(separator: "=", maxSplits: 1)
            guard field.count == 2 else { continue }
            let key = String(field[0]), value = String(field[1])
            if key == "client-sha256", value.utf8.count == 64,
               value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                report.fields[key] = value
            } else if key == "session-callback-id", let number = Int32(value) {
                // Valve's callback IDs after sign-in (the host reports the first 16), in
                // order, as one field: the poll logs a field only when it changes.
                let ids = report.fields["session-callback-ids"]
                if (ids?.split(separator: ",").count ?? 0) < 16 {
                    report.fields["session-callback-ids"] = (ids.map { $0 + "," } ?? "") + String(number)
                }
            } else if reportAllowed.contains(key), let number = Int32(value) {
                report.fields[key] = String(number)
            }
        }
        return report
    }

    @MainActor private static var lastReport = Report()

    /// Reads C:\madeira-dock.txt and logs fields that changed ([dock-report]).
    @MainActor static func pollReport() -> Report {
        let url = drive.appendingPathComponent("madeira-dock.txt")
        guard let file = try? FileHandle(forReadingFrom: url) else { return lastReport }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 32769), data.count <= 32768 else { return lastReport }
        let report = parseReport(data)
        for key in report.fields.keys.sorted() where report.fields[key] != lastReport.fields[key] {
            SteamLog.event("[dock-report] \(key)=\(report.fields[key]!)")
        }
        // The host ended: its whole report, in order, so the sequence and repeats of
        // its numeric fields are in the diagnostic log (each line is `[steam-host]
        // <round> <field>=<number>`; nothing else is in the file).
        if report.fields["probe-result"] != nil, lastReport.fields["probe-result"] == nil {
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("[steam-host] ") }
            SteamLog.event("[dock-report-file] lines=\(lines.count)")
            for line in lines.prefix(400) { SteamLog.event("[dock-report-file] " + line.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        lastReport = report
        return report
    }

    // MARK: Launch

    private static var transferURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MadeiraDock", isDirectory: true).appendingPathComponent("launch.auth")
    }

    /// Removes an unconsumed transfer (session end, sign-out, app start).
    @MainActor static func cleanup() {
        if let url = transferURL { try? FileManager.default.removeItem(at: url) }
        unsetenv("MADEIRA_DOCK_AUTH_FILE")
        unsetenv("MADEIRA_DOCK_OFFLINE")
    }

    /// Writes the one-use transfer to protected Application Support storage
    /// (complete file protection, mode 0600, excluded from backups, created
    /// exclusively) and puts only its guest path in the environment. No
    /// token, account name or path is logged.
    @MainActor static func writeHandoff(account: String, token: String, appID: Int) throws {
        cleanup()
        lastReport = Report()
        let report = drive.appendingPathComponent("madeira-dock.txt")
        if FileManager.default.fileExists(atPath: report.path) { try FileManager.default.removeItem(at: report) }
        guard let url = transferURL else { throw DockError.message("Dock 的私有传递文件夹不可用。") }
        var data = try envelope(account: account, token: token, steamID: subject(token), appID: appID)
        defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
        let fm = FileManager.default
        var folder = url.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw DockError.message("Dock 的传递文件夹无效。")
        }
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DockError.message("Madeira 无法创建 Dock 的私有登录传递文件。") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            try file.write(contentsOf: data); try file.close()
            setenv("MADEIRA_DOCK_AUTH_FILE", handoffGuestPath(url), 1)
            SteamLog.event("[dock-handoff] protected-file-ready=1")
        } catch { try? file.close(); cleanup(); throw error }
    }

    /// The host's environment for one launch.
    static func configure(_ game: DockGame, launchOption: UInt32 = 0) {
        for key in ["MADEIRA_STEAM_HOST_PROBE", "MADEIRA_STEAM_HOST_SESSION", "MADEIRA_STEAM_HOST_LOGIN", "MADEIRA_STEAM_HOST_LAUNCH"] {
            setenv(key, "1", 1)
        }
        setenv("MADEIRA_STEAM_HOST_APPID", String(game.id), 1)
        setenv("MADEIRA_STEAM_HOST_LAUNCH_OPTION", String(launchOption), 1)
        setenv("MADEIRA_STEAM_HOST_CLIENT_DIR", SteamRuntimeFiles.windowsRoot, 1)
        setenv("MADEIRA_STEAM_HOST_EXPECTED_INSTALL", game.windowsInstallPath, 1)
        setenv("MADEIRA_STEAM_HOST_LOG", "C:\\madeira-dock.txt", 1)
        // The install record lists per-user executables: Dock asks Valve's client to prepare
        // them before it launches. env.MADEIRA_DOCK_CEG = 0 never asks.
        if game.customExecutables && SteamSignIn.flag("MADEIRA_DOCK_CEG", default: true) {
            setenv("MADEIRA_STEAM_HOST_CEG", "1", 1)
        } else {
            unsetenv("MADEIRA_STEAM_HOST_CEG")
        }
        // Never let a stale environment choose the PC cached-account test path.
        unsetenv("MADEIRA_STEAM_HOST_ACCOUNT"); unsetenv("MADEIRA_STEAM_HOST_STEAMID")
        // Valve's client unloads DLLs while it starts and the loader can map a different
        // DLL of the same size at the same address. The engine's opt-in image-retire
        // switch (MADEIRA_JIT_IMAGE_RETIRE, off for every other session) gives that DLL
        // fresh code instead of the unloaded one's translation. Dock sessions turn it on;
        // an engine without the switch ignores the variable. env.MADEIRA_DOCK_IMAGE_RETIRE = 0
        // leaves it off, and an explicit env.MADEIRA_JIT_IMAGE_RETIRE in madeira.cfg still wins.
        let retire = SteamSignIn.flag("MADEIRA_DOCK_IMAGE_RETIRE", default: true)
        if retire { setenv("MADEIRA_JIT_IMAGE_RETIRE", "1", 1) }
        SteamLog.event("[dock-launch] image-retire=\(retire ? 1 : 0)")
        // While the loader loads Valve's client and its many imports, the emulator's
        // image-map handler can commit a page of its own heap under its interval lock; the
        // commit's notification then waits for that same lock and the host parks for good
        // (no report after load-client-begin). Wine's opt-in MADEIRA_IMAGE_MAP_GUARD (off for
        // every other session) keeps the emulator's own memory calls un-notified there, as
        // on the syscall path. Dock sessions turn it on; ntdll without the switch ignores it.
        // env.MADEIRA_DOCK_IMAGE_MAP_GUARD = 0 leaves it off.
        let guardMap = SteamSignIn.flag("MADEIRA_DOCK_IMAGE_MAP_GUARD", default: true)
        if guardMap { setenv("MADEIRA_IMAGE_MAP_GUARD", "1", 1) }
        SteamLog.event("[dock-launch] image-map-guard=\(guardMap ? 1 : 0)")
        DockOffline.configure(appID: game.id)
    }

    /// Wine's explorer opens a virtual desktop and starts the host in it. With
    /// `installers` (DockInstallers.script), cmd.exe first runs the game's one-time
    /// installs in the same session, then the host. No token is quoted: MADEIRA_ARGS is
    /// split at spaces and passed on as is, so quote characters would reach Wine
    /// literally, and none of these paths contains a space.
    /// madeira-bcd: `host` false runs only the installers; the session ends after them
    /// (DockInstallers.installsOnly).
    static func launchArguments(width: Int, height: Int, installers: String? = nil, host: Bool = true) -> String {
        guard let installers else { return "/desktop=madeira,\(width)x\(height) \(executable)" }
        guard host else { return "/desktop=madeira,\(width)x\(height) C:\\windows\\system32\\cmd.exe /c call \(installers)" }
        return "/desktop=madeira,\(width)x\(height) C:\\windows\\system32\\cmd.exe /c call \(installers) & \(executable)"
    }

    /// Set on the main actor right before a Dock launch; read (and cleared) once by the
    /// launch worker, so only that launch sees it.
    nonisolated(unsafe) private static var launchRequest: (dock: Bool, compact: Bool) = (false, false)
    static func requestLaunch(compactPool: Bool) { launchRequest = (true, compactPool) }
    static func takeLaunchRequest() -> (dock: Bool, compact: Bool) {
        defer { launchRequest = (false, false) }
        return launchRequest
    }
}

/// Offline play for Steam games started through Madeira Dock.
///
/// Valve's client can log an account on without a connection, with an offline
/// logon ticket Steam issues to it during an online logon (desktop Steam's
/// Offline Mode). The host asks the client for exactly that (madeira-dock
/// docs/OFFLINE.md): Madeira decides nothing about ownership and stores no
/// ticket. What lives here is only what the app needs around it:
///
/// - whether the device has a network path, so a start without one asks for the
///   offline logon straight away (`MADEIRA_DOCK_OFFLINE=1`) instead of waiting
///   out a connection that cannot happen;
/// - a note of the last online start in which Valve's client confirmed a licence
///   and said the account can log on offline (the host's
///   `session-offline-ready=1`), for the Game details mark. Steam's offline
///   sign-in belongs to the ACCOUNT: with it, Valve's client answers the licence
///   question for any game from the list it cached, whether or not that game was
///   ever started online. So the note is one date for the account, plus the games
///   started online since, which matters only for a game whose per-user
///   executable Steam prepares on its first start (that needs a connection). It
///   is a display aid: an offline start is always decided by Valve's client.
///
/// `env.MADEIRA_DOCK_OFFLINE_LOGON = 0` removes the feature in the app and in
/// the host (which reads the same variable).
enum DockOffline {
    static let enabled = SteamSignIn.flag("MADEIRA_DOCK_OFFLINE_LOGON", default: true)

    private static let monitor = NWPathMonitor()
    private static var started = false
    /// Starts the path monitor. Called at app start, so the path is current by
    /// the time anything is launched.
    static func begin() {
        guard enabled, !started else { return }
        started = true
        monitor.start(queue: DispatchQueue(label: "madeira.dock-offline.path"))
    }
    /// No usable network path right now. False until the monitor has started.
    static var networkDown: Bool { started && monitor.currentPath.status != .satisfied }

    private static let key = "madeiraDockOfflineVerified", accountKey = "madeiraDockOfflineAccount"
    /// When Valve's client last reported, in an online start, that it can log this
    /// account on offline; nil if it never has on this installation.
    static var accountSaved: Date? {
        guard enabled else { return nil }
        var t = UserDefaults.standard.double(forKey: accountKey)
        // A build that kept only the per-game dates: the newest of those is the account's.
        if t <= 0, let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] {
            t = all.values.max() ?? 0
        }
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    /// When this game last started online in such a session; nil if it never has.
    static func verified(_ appID: Int) -> Date? {
        guard enabled, let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double],
              let t = all[String(appID)] else { return nil }
        return Date(timeIntervalSince1970: t)
    }
    /// What Game details says about a game the Dock starts.
    enum Mark: Equatable {
        case ready(Date)        // Steam can sign in offline; this game needs nothing more
        case needsFirstStart    // Steam can sign in offline, but prepares this game's program online first
        case needsOnline        // Steam has no offline sign-in saved yet
    }
    /// `preparedOnline`: the game's install record lists per-user executables,
    /// which Valve's client prepares on the first start, over the network.
    static func mark(_ appID: Int, preparedOnline: Bool) -> Mark {
        guard let saved = accountSaved else { return .needsOnline }
        if preparedOnline, verified(appID) == nil { return .needsFirstStart }
        return .ready(saved)
    }
    private static func save(_ appID: Int) {
        let now = Date().timeIntervalSince1970
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        all[String(appID)] = now
        UserDefaults.standard.set(all, forKey: key)
        UserDefaults.standard.set(now, forKey: accountKey)
    }
    /// Sign-in removed or changed: the notes belonged to that account.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: accountKey)
    }

    /// The app the running Dock session was started for.
    private(set) static var sessionApp: Int?
    private static var sessionMarked = false

    /// Part of MadeiraDock.configure: tells the host when there is no network.
    static func configure(appID: Int) {
        sessionApp = appID
        sessionMarked = false
        let offline = enabled && networkDown
        if offline { setenv("MADEIRA_DOCK_OFFLINE", "1", 1) } else { unsetenv("MADEIRA_DOCK_OFFLINE") }
        SteamLog.event("[dock-offline] enabled=\(enabled ? 1 : 0) network=\(networkDown ? "down" : "up") request=\(offline ? 1 : 0) account-saved=\(accountSaved != nil ? 1 : 0) game-started-online=\(verified(appID) != nil ? 1 : 0)")
    }

    /// Follows the host's report (MadeiraDockModel.watchReport): an online start
    /// in which Valve's client confirmed the licence and reported that it can log
    /// the account on offline saves the game for offline play.
    @MainActor static func observe(_ fields: [String: String]) {
        guard enabled, !sessionMarked, let app = sessionApp,
              fields["session-offline-requested"] == nil,
              fields["session-requested-app-listed"] == "1",
              fields["session-offline-ready"] == "1" else { return }
        sessionMarked = true
        save(app)
        SteamLog.event("[dock-offline] Valve's client can log this account on offline: saved")
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static let changed = Notification.Name("MadeiraDockOfflineChanged")
}
