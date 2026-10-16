// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). The sign-in
// errors are the ones sign-in raises; the connection, library and download
// errors belong to the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation

/// Errors raised by the Steam sign-in, library and download code.
enum SteamError: LocalizedError, Equatable {
    /// Logon EResults that mean the stored sign-in token itself is unusable:
    /// InvalidPassword, AccessDenied, AccountNotFound, Revoked, Expired,
    /// InvalidSignature.
    static let signInExpiredCodes: Set<UInt32> = [5, 15, 18, 26, 27, 94]

    // Sign-in
    case authenticationFailed(String)
    case invalidCredentials
    case rateLimited
    case accountDisabled
    case rsaKeyFetchFailed
    case qrCodeExpired
    case authSessionExpired
    case protobufError(String)

    // Connection
    case noServersAvailable
    case connectionFailed(String)
    case connectionTimeout
    case disconnected
    /// The CM refused the logon with this EResult. Lets callers tell a revoked
    /// or expired sign-in from a transient network failure.
    case logonDenied(UInt32)
    case invalidMessage

    // Library
    case appInfoNotFound(UInt32)
    case depotNotFound(UInt32)

    // Content
    case manifestFetchFailed(String)
    case chunkDownloadFailed(String)
    case decryptionFailed(String)
    case decompressionFailed
    /// A downloaded chunk could not be decoded; the value names the encoding
    /// (vzip, vzstd, zip) or its leading bytes.
    case chunkDecodeFailed(String)
    case checksumMismatch
    case depotKeyNotFound(UInt32)
    case insufficientDiskSpace(needed: UInt64, available: UInt64)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let reason):
            return reason
        case .invalidCredentials:
            return "账户名称或密码不正确。"
        case .rateLimited:
            return "尝试次数过多。请稍后重试。"
        case .accountDisabled:
            return "此 Steam 账户已被停用"
        case .rsaKeyFetchFailed:
            return "无法获取用于加密密码的 RSA 公钥"
        case .qrCodeExpired:
            return "二维码已过期。请重试。"
        case .authSessionExpired:
            return "登录请求已过期。请重新开始。"
        case .protobufError(let detail):
            return "Protocol Buffers 错误：\(detail)"
        case .noServersAvailable:
            return "没有可用的 Steam 服务器。"
        case .connectionFailed(let reason):
            return "连接失败：\(reason)"
        case .connectionTimeout:
            return "Steam 响应超时。请检查网络连接后重试。"
        case .disconnected:
            return "已与 Steam 断开连接。"
        case .logonDenied(let code):
            return SteamError.signInExpiredCodes.contains(code)
                ? "Steam 登录已失效。请重新登录。"
                : "Steam 拒绝连接（代码 \(code)）。请稍后重试。"
        case .invalidMessage:
            return "收到了来自 Steam 的无效消息。"
        case .appInfoNotFound(let appID):
            return "Steam 没有应用 \(appID) 的信息。"
        case .depotNotFound:
            return "Steam 没有此游戏的 Windows 下载版本。"
        case .manifestFetchFailed(let reason):
            return "无法读取游戏文件列表：\(reason)"
        case .chunkDownloadFailed(let reason):
            return "下载失败：\(reason)"
        case .decryptionFailed(let reason):
            return "解密失败：\(reason)"
        case .decompressionFailed:
            return "无法解压下载的数据。"
        case .chunkDecodeFailed(let format):
            return "无法解码部分游戏内容（\(format)）。请重试；已下载的部分会保留。"
        case .checksumMismatch:
            return "某个下载分块未通过校验。"
        case .depotKeyNotFound:
            return "Steam 不允许此账户下载游戏文件。请确认账户拥有此游戏。"
        case .insufficientDiskSpace(let needed, let available):
            return String(format: "可用空间不足：下载需要 %.1f GB，目前可用 %.1f GB。",
                          Double(needed) / 1_000_000_000, Double(available) / 1_000_000_000)
        }
    }
}

/// Where a Steam Guard code comes from.
enum SteamGuardType: String, Codable {
    case email = "email"
    case device = "device"          // Steam Mobile Authenticator
}
