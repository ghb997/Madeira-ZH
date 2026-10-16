// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

/// Steam sign-in sheet: account name + password with Steam Guard (a code and
/// in-app approval, offered together when Steam allows both), or a QR code
/// scanned with the Steam app (default on iPad). When signed in it shows the
/// account and Sign out.
struct SteamSignInView: View {
    @ObservedObject private var steam = SteamSignInModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var method: SteamSignInModel.SignInMethod = UIDevice.current.userInterfaceIdiom == .pad ? .qr : .password
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var focus: Field?
    private enum Field { case account, password, code }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("登录 Steam", systemImage: "person.crop.circle.fill").font(.title2.bold())
                        Text("Madeira 会保存 Steam 登录信息，以便使用你自己的账户启动 Steam 游戏。")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                if let name = steam.accountName {
                    signedInSection(name)
                } else if let prompt = steam.guardPrompt {
                    guardSection(prompt)
                } else {
                    Section {
                        Picker("登录方式", selection: $method) {
                            Text("密码").tag(SteamSignInModel.SignInMethod.password)
                            Text("二维码").tag(SteamSignInModel.SignInMethod.qr)
                        }.pickerStyle(.segmented)
                    }
                    if method == .password { passwordSection } else { qrSection }
                }
                if let error = steam.signInError {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    Text("Madeira 直接向 Steam 登录。密码仅发送给 Steam，且不会保存。登录令牌保存在此设备的钥匙串中，退出登录时会移除。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Steam").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(steam.signedIn ? "完成" : "取消") { steam.cancelSignIn(); dismiss() }
                }
            }
            .onAppear {
                steam.refresh(); steam.signInError = nil
                guard !steam.signedIn else { return }
                if method == .qr { steam.beginQR() } else { focus = .account }
            }
            .onChange(of: method) { _, value in
                steam.signInError = nil
                guard !steam.signedIn else { return }
                if value == .qr { steam.beginQR() } else { steam.cancelSignIn(); focus = .account }
            }
            .onChange(of: steam.accountName) { _, name in if name != nil { dismiss() } }
            .onChange(of: steam.guardPrompt) { _, prompt in if prompt?.codeType != nil { focus = .code } }
            .onDisappear { if !steam.signedIn { steam.cancelSignIn() } }
        }
    }

    private func signedInSection(_ name: String) -> some View {
        Section {
            LabeledContent("账户", value: name)
            Button("退出登录", role: .destructive) { steam.signOut() }
        } footer: {
            Text("退出登录会移除此设备钥匙串中的令牌。")
        }
    }

    private var passwordSection: some View {
        Section {
            TextField("Steam 账户名称", text: $account)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focus, equals: .account).submitLabel(.next).onSubmit { focus = .password }
            SecureField("密码", text: $password)
                .textContentType(.password).focused($focus, equals: .password)
                .submitLabel(.go).onSubmit(submit)
            Button(action: submit) {
                HStack {
                    Text("登录").fontWeight(.semibold)
                    if steam.signInBusy { Spacer(); ProgressView() }
                }
            }.disabled(account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || steam.signInBusy)
        } footer: {
            Text("请输入 Steam 账户名称，它可能与你的邮箱地址不同。")
        }
    }

    private func submit() {
        guard !account.isEmpty, !password.isEmpty, !steam.signInBusy else { return }
        steam.signIn(account: account, password: password)
        password = ""
    }

    private func guardSection(_ prompt: SteamGuardPrompt) -> some View {
        Section {
            if let type = prompt.codeType {
                Text(type == .device
                     ? "请输入手机 Steam App 中显示的 Steam 令牌验证码。"
                     : "请输入 Steam 发送到你邮箱的验证码" + (prompt.hint.isEmpty ? "." : " (\(prompt.hint))."))
                TextField("验证码", text: $code)
                    .textContentType(.oneTimeCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.title3.monospaced()).focused($focus, equals: .code)
                    .submitLabel(.go).onSubmit { steam.submitGuardCode(code) }
                Button {
                    steam.submitGuardCode(code)
                } label: {
                    HStack { Text("继续").fontWeight(.semibold); if steam.signInBusy { Spacer(); ProgressView() } }
                }.disabled(code.trimmingCharacters(in: .whitespaces).count < 5 || steam.signInBusy)
            }
            if prompt.canApprove {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(prompt.codeType == nil
                         ? "请在手机 Steam App 中批准此次登录。"
                         : "也可在 Steam App 中批准此次登录。")
                        .foregroundStyle(.secondary)
                }
            }
            Button("重新开始", role: .cancel) { code = ""; steam.cancelSignIn() }
        } header: { Text("Steam 令牌") }
    }

    private var qrSection: some View {
        Section {
            if let image = steam.qrImage {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                    .frame(maxWidth: 240).padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Steam 登录二维码")
                Text("请在另一台设备上打开 Steam App，进入“Steam 令牌”并扫描此二维码。")
                if let link = steam.qrLink {
                    Button { UIApplication.shared.open(link) } label: {
                        Label("在此设备的 Steam App 中打开", systemImage: "arrow.up.forward.app")
                    }
                }
                HStack(spacing: 12) { ProgressView(); Text("正在等待批准…").foregroundStyle(.secondary) }
            } else if steam.signInBusy {
                HStack(spacing: 12) { ProgressView(); Text("正在获取登录二维码…").foregroundStyle(.secondary) }
            } else {
                Button("获取新二维码") { steam.beginQR() }
            }
        }
    }
}
