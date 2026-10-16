//
//  GameRecommendationsApply.swift
//  Madeira
//
//  madeira-bcd: writes GameRecommendations.swift's lists into a game's
//  settings (owner's decision, 2026-10-09).
//
//  The first time Madeira sees a game it has a recommendation for (a Steam
//  download finishing, the library opening or saving the game, Game details
//  opening, a start):
//    - with nothing of its own yet (no config file, no lines in upstream's
//      `config` field), a game new to the library gets its whole
//      recommendation, and one already in the library the config file only:
//      its fields and switches (resolution, FPS limit, AVX ...) stay the
//      player's until Reset to Recommended;
//    - with a config of its own, it keeps it, and only Reset to Recommended
//      replaces it.
//  A config Madeira wrote that nobody has changed since follows a newer
//  version of its list (the config file only); one the player changed, or
//  emptied, is never written again by itself. "Reset to Recommended" at the
//  bottom of the game's settings writes the whole recommendation again,
//  whatever the game holds; for a game without one it empties the game's
//  config. A game without a list of its own, and the Desktop, gets the
//  standard list (owner's decisions, 2026-10-12), which a list for the game
//  replaces later as on first sight while nobody has changed the file.
//
//  The config file and the switches LibraryPrefs keeps belong to the game's
//  Windows path. A library entry's own fields (fastsync, FPS limit,
//  resolution, scaling) are written with them, or later for an entry new to
//  the library.
//

import Foundation

extension GameRecommendations {
    /// What Madeira did for which game: [lowercased Windows path: "<id>#<version>#<file hash>"
    /// for a recommendation it wrote, "" for a game that kept its own config].
    private static let appliedKey = "madeira.recommended.applied"

    private enum Write: String { case firstSight = "first sight", updated, reset }

    /// The recommendation for a game in drive_c: a program, or a Steam game's install folder.
    /// A game Madeira has no list for gets the standard one; a path that names nothing, none.
    static func recommendation(windowsPath: String, steamAppID: Int?) -> GameRecommendation? {
        if let rec = match(windowsPath: windowsPath, steamAppID: steamAppID, fileExists: driveFileExists) { return rec }
        let parts = windowsPath.replacingOccurrences(of: "/", with: "\\").split(separator: "\\")
        return parts.count > 1 ? standard : nil
    }

    /// A library entry's recommendation: the Desktop's is the standard list.
    static func recommendation(for entry: LibraryEntry) -> GameRecommendation? {
        entry.desktop == true ? standard : recommendation(windowsPath: entry.windowsPath, steamAppID: entry.steamAppID)
    }

    /// A library entry's recommendation, when one is due (see above). `new`: the entry
    /// is not in the library yet; it then also takes the fields of a list written for
    /// its game before (for an entry since removed). True when the entry's own fields
    /// changed, so the caller saves the entry.
    @discardableResult
    static func prepare(_ entry: inout LibraryEntry, new: Bool = false) -> Bool {
        if let found = due(entry.windowsPath, recommendation(for: entry), ownLines: entry.config, title: entry.title),
           put(found.rec, to: entry.windowsPath, found.kind, title: entry.title, switches: new), found.kind == .firstSight {
            // A game already in the library keeps its own fields and switches (resolution,
            // FPS limit, AVX ...): the player may have set them. It gets the config file only;
            // Reset to Recommended brings the rest.
            guard new else {
                LogStore.shared.log("[recommended] \(entry.title): \(found.rec.id) v\(found.rec.version) config only; "
                                    + "the entry keeps its own fields and switches")
                return false
            }
            takeEntryFields(found.rec, &entry)
            return true
        }
        // After an update too: a new entry takes the list now recorded for its path.
        guard new, let mark = marks[entry.windowsPath.lowercased()], !mark.isEmpty,
              let rec = recommendation(for: entry), mark.hasPrefix(rec.id + "#") else { return false }
        takeEntryFields(rec, &entry)
        LogStore.shared.log("[recommended] \(entry.title): \(rec.id) v\(rec.version) fields for a new library entry")
        return true
    }

    /// Game details › Reset to Recommended. Returns what was written; nil when the
    /// game has no recommendation and its config was emptied.
    @discardableResult
    static func reset(_ entry: inout LibraryEntry) -> GameRecommendation? {
        entry.config = nil
        guard let rec = recommendation(for: entry) else { clear(entry.windowsPath, title: entry.title); return nil }
        put(rec, to: entry.windowsPath, .reset, title: entry.title)
        takeEntryFields(rec, &entry)
        return rec
    }

    /// The line under Reset to Recommended. `desktop`: the Desktop entry's page.
    static func note(_ rec: GameRecommendation?, desktop: Bool = false) -> String {
        guard let rec else { return "Madeira 尚未提供此游戏的推荐设置；重置将清空此游戏的配置。" }
        let lines = GameProfile.parse(rec.config).count
        if rec.id == standard.id {
            return (desktop ? "Madeira 建议桌面使用标准设置："
                            : "Madeira 尚未提供此游戏的专用配置，建议使用标准设置：")
                + "\(lines) 行配置（关闭模拟器的代码补丁报告，否则许多游戏会在启动时退出）。重置会用这些设置替换"
                + (desktop ? "桌面" : "此游戏") + "的配置。"
        }
        let summary = rec.switchSummary
        let switches = summary.isEmpty ? "" : "; " + summary
        return "Madeira 为 \(rec.title) 推荐的设置：\(lines) 行配置\(switches)。重置会用这些设置替换此游戏的配置和开关。"
    }

    /// The question before a reset.
    static func question(_ rec: GameRecommendation?, desktop: Bool = false) -> String {
        guard let rec else { return "Madeira 尚未提供此游戏的推荐设置。要清空此游戏的配置吗？" }
        if rec.id == standard.id {
            return "将\(desktop ? "桌面" : "此游戏")的配置替换为 Madeira 的标准设置？你所做的更改将会丢失。"
        }
        return "将此游戏的配置和开关替换为 Madeira 为 \(rec.title) 推荐的设置？你所做的更改将会丢失。"
    }

    // MARK: -

    private static func due(_ windowsPath: String, _ found: GameRecommendation?, ownLines: String?,
                            title: String) -> (rec: GameRecommendation, kind: Write)? {
        let mark = marks[windowsPath.lowercased()]
        guard mark != "", let rec = found else { return nil }
        let text = GameProfile(windowsPath: windowsPath).text
        if let mark {
            // Written before: a newer list replaces it while the file is exactly what was written.
            guard mark != stamp(rec), mark.hasSuffix("#" + fileHash(text)) else { return nil }
            // The standard list gives way to the game's own list as on first sight, switches too.
            let fromStandard = mark.hasPrefix(standard.id + "#") && rec.id != standard.id
            return (rec: rec, kind: fromStandard ? Write.firstSight : Write.updated)
        }
        if !(text + (ownLines ?? "")).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // First seen with a config of its own: it stays, now and later.
            setMark("", windowsPath)
            LogStore.shared.log("[recommended] \(title): keeps its own config; \(rec.id) v\(rec.version) is one Reset to Recommended away")
            return nil
        }
        return (rec: rec, kind: .firstSight)
    }

    /// The config file, and on first sight or a reset the switches LibraryPrefs keeps for
    /// the game's path: AVX, NVIDIA and Wine's C++ runtime.
    @discardableResult
    private static func put(_ rec: GameRecommendation, to windowsPath: String, _ kind: Write, title: String,
                            switches: Bool = true) -> Bool {
        let file = GameProfile(windowsPath: windowsPath)
        file.text = rec.fileText
        guard file.text == rec.fileText else {
            LogStore.shared.log("[recommended] \(title): could not write \(rec.id)", level: .error)
            return false
        }
        if kind != .updated && switches {
            if let on = rec.avx { LibraryPrefs.setAVX(on, for: windowsPath) }
            if let on = rec.nvidia { LibraryPrefs.setNvidia(on, for: windowsPath) }
            if let on = rec.wineVCRT { LibraryPrefs.setWineVCRT(on, for: windowsPath) }
        }
        setMark(stamp(rec), windowsPath)
        LogStore.shared.log("[recommended] \(title): \(rec.id) v\(rec.version) written (\(kind.rawValue))")
        return true
    }

    private static func clear(_ windowsPath: String, title: String) {
        GameProfile(windowsPath: windowsPath).text = ""
        setMark(nil, windowsPath)
        LogStore.shared.log("[recommended] \(title): none for this game; its config was emptied (reset)")
    }

    /// The switches a library entry keeps itself.
    private static func takeEntryFields(_ rec: GameRecommendation, _ entry: inout LibraryEntry) {
        if let on = rec.fastSync { entry.fastSync = on }
        if let on = rec.semaphoreFastPath { entry.semaphoreFastPath = on }
        if let mode = rec.fpsMode { entry.fpsMode = mode }
        if let size = rec.resolution {
            // This screen's shape at 720 lines; a screen whose default has them keeps its own.
            if size != GameRecommendation.screen720 { entry.resolution = size }
            else if let lines720 = ResolutionChoices.screen720Value { entry.resolution = lines720 }
        }
        if let mode = rec.display { entry.display = mode == DisplayMode.fit.rawValue ? nil : mode }
    }

    private static var marks: [String: String] {
        (UserDefaults.standard.dictionary(forKey: appliedKey) as? [String: String]) ?? [:]
    }

    private static func setMark(_ value: String?, _ windowsPath: String) {
        var all = marks
        all[windowsPath.lowercased()] = value
        UserDefaults.standard.set(all, forKey: appliedKey)
    }

    private static func stamp(_ rec: GameRecommendation) -> String { "\(rec.id)#\(rec.version)#\(fileHash(rec.fileText))" }

    private static func fileHash(_ text: String) -> String { String(LibraryPrefs.stableHash(text), radix: 16) }

    /// Whether a C:\ path exists in drive_c; the name's case does not matter, as on Windows.
    static func driveFileExists(_ windowsPath: String) -> Bool {
        let path = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard path.lowercased().hasPrefix("c:/") else { return false }
        let url = LibraryModel.drive.appendingPathComponent(String(path.dropFirst(3)))
        let name = url.lastPathComponent.lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.contains { $0.lowercased() == name }
    }
}
