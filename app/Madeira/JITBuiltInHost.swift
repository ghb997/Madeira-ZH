// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

/// The private NSExtension API (ExtensionFoundation) that starts an app extension of
/// Madeira's own: the same calls LiveContainer uses to start its LiveProcess.
@objc private protocol NSExtensionClassShim {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol NSExtensionShim {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(pidForRequestIdentifier:)
    func pid(forRequestIdentifier identifier: NSUUID) -> Int32
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}

/// Starts the separate helper process required to debug Madeira without
/// deadlocking Madeira itself.
///
/// The helper is a classic app extension (PlugIns/MadeiraJITHelper.appex, on
/// com.apple.ar.viewer as LiveContainer's LiveProcess is), started by the bundle ID it
/// has in this installation. Sideloaders that sign with the user's own Apple ID rename
/// Madeira's bundle ID and the helper's along with it (SideStore, AltStore and Plume
/// append the team ID), and that is all this lookup needs. An ExtensionKit extension
/// point, which the helper used before, is named in files sideloaders do not rewrite, so
/// iOS registered none for a renamed Madeira ("Failed to add observer").
///
/// One extension request per MadeiraJITRequest: the request goes as JSON in the input
/// item's userInfo, and the helper completes the request with the JSON response in the
/// returned item's userInfo. Log tag: [jit-helper].
@MainActor
enum MadeiraBuiltInJIT {
    static let helperFile = "MadeiraJITHelper.appex"

    /// Requests that have started and not finished, kept alive until they do.
    private static var running: [HelperRequest] = []

    static var unavailableReason: String? {
#if targetEnvironment(simulator)
        return "内置 JIT 仅支持实体设备。"
#else
        guard #available(iOS 26.0, *) else {
            return "内置 JIT 需要 iOS 26 或更高版本。"
        }
        if getenv("LC_HOME_PATH") != nil {
            return "LiveContainer 中无法使用内置 JIT，请选择 StikDebug。"
        }
        return nil
#endif
    }

    static var isAvailable: Bool { unavailableReason == nil }

    /// The helper's bundle ID in this installation, read from its own Info.plist; nil when
    /// a sideloader left it out.
    static var helperIdentifier: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(helperFile) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    static func send(_ request: MadeiraJITRequest,
                     started: @escaping () -> Void = {},
                     completion: @escaping (Result<MadeiraJITRequest.Response, Error>) -> Void) {
        func fail(_ code: Int, _ message: String) {
            LogStore.shared.log("[jit-helper] \(message)", level: .error)
            completion(.failure(NSError(domain: "MadeiraBuiltInJIT", code: code,
                                        userInfo: [NSLocalizedDescriptionKey: message])))
        }
        guard unavailableReason == nil else {
            fail(1, unavailableReason ?? "内置 JIT 不可用。")
            return
        }
        guard let identifier = helperIdentifier else {
            fail(2, "当前安装缺少 Madeira 的 JIT 助手。请重新安装 Madeira；如果侧载工具询问，请保留应用扩展。")
            return
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension") else {
            fail(3, "iOS 未提供 Madeira 的 JIT 助手所需的扩展 API。")
            return
        }
        let factory = unsafeBitCast(extensionClass as AnyObject, to: NSExtensionClassShim.self)
        let found: AnyObject
        do { found = try factory.extension(withIdentifier: identifier) }
        catch {
            fail(2, "找不到 Madeira 的 JIT 助手（\(identifier)）：\(error.localizedDescription) 请重新安装 Madeira。")
            return
        }
        guard let data = try? JSONEncoder().encode(request) else {
            fail(4, "无法编码发送给 Madeira JIT 助手的请求。")
            return
        }
        let helper = HelperRequest(extension: found, operation: request.operation.rawValue, completion: completion)
        running.append(helper)
        helper.begin(data: data, identifier: identifier, started: started)
    }

    fileprivate static func finished(_ helper: HelperRequest) {
        running.removeAll { $0 === helper }
    }
}

/// One request to the helper, from its start to its one result.
@MainActor
private final class HelperRequest {
    private let shim: NSExtensionShim
    private let `extension`: AnyObject   // the NSExtension, kept alive for the request
    private let operation: String
    private var completion: ((Result<MadeiraJITRequest.Response, Error>) -> Void)?

    init(extension found: AnyObject, operation: String,
         completion: @escaping (Result<MadeiraJITRequest.Response, Error>) -> Void) {
        self.extension = found
        self.shim = unsafeBitCast(found, to: NSExtensionShim.self)
        self.operation = operation
        self.completion = completion
    }

    func begin(data: Data, identifier: String, started: @escaping () -> Void) {
        // The blocks can arrive on any queue; everything below runs on the main thread.
        shim.setRequestCompletionBlock { [weak self] _, items in
            let info = (items?.first as? NSExtensionItem)?.userInfo
            let payload = info?[MadeiraJITRequest.Response.itemKey] as? Data
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.returned(payload) } }
        }
        shim.setRequestCancellationBlock { [weak self] _, error in
            let message = error?.localizedDescription ?? "请求已取消"
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(Self.error(5, "Madeira 的 JIT 助手已停止：\(message)")))
            } }
        }
        shim.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.end(.failure(Self.error(6, "Madeira 的 JIT 助手意外停止，请重试。")))
            } }
        }
        let item = NSExtensionItem()
        item.userInfo = [MadeiraJITRequest.itemKey: data]
        shim.beginExtensionRequest(withInputItems: [item]) { [weak self] uuid in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                guard let self else { return }
                guard let uuid else {
                    self.end(.failure(Self.error(7, "Madeira 的 JIT 助手未能启动。请重新安装 Madeira；如果侧载工具询问，请保留应用扩展。")))
                    return
                }
                LogStore.shared.log("[jit-helper] \(self.operation): started \(identifier) as pid \(self.shim.pid(forRequestIdentifier: uuid))")
                started()
            } }
        }
    }

    private func returned(_ payload: Data?) {
        guard let payload, let response = try? JSONDecoder().decode(MadeiraJITRequest.Response.self, from: payload) else {
            end(.failure(Self.error(8, "Madeira 的 JIT 助手已结束，但未返回结果。")))
            return
        }
        LogStore.shared.log("[jit-helper] \(operation): finished success=\(response.success ? 1 : 0)")
        end(.success(response))
    }

    private func end(_ result: Result<MadeiraJITRequest.Response, Error>) {
        guard let completion else { return }   // the first result counts
        self.completion = nil
        if case .failure(let error) = result {
            LogStore.shared.log("[jit-helper] \(operation): \(error.localizedDescription)", level: .error)
        }
        MadeiraBuiltInJIT.finished(self)
        completion(result)
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "MadeiraBuiltInJIT", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
