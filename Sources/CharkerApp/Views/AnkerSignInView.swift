import CharkerCore
import SwiftUI

/// One-shot Anker sign-in, used only to read the account id the charger checks.
///
/// This is the app's only network request. It is deliberately explicit about what
/// happens to the password, because asking for someone's account credentials
/// inside a third-party app deserves a plain answer rather than a shrug.
struct AnkerSignInView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var email = ""
    @State private var password = ""
    @State private var country = ""
    @State private var loginTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.contains("@") && address.count >= 5 && address.contains(".")
            && !password.isEmpty && country.count == 2 && !model.isSigningIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            form
            disclosure
            Divider().overlay(Palette.stroke)
            footer
        }
        .padding(Space.xl)
        .frame(width: 440)
        .background(Palette.surface)
        .tint(Palette.accent)
        .onAppear {
            if country.isEmpty { country = model.defaultCountryCode }
            // Focus set directly in onAppear races the sheet's key-window
            // handshake and frequently lands nowhere.
            DispatchQueue.main.async { focus = .email }
        }
        .onDisappear { loginTask?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("用 Anker 账号获取 ID")
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)
            Text("登录一次获取账号 ID，之后长期有效。充电器只认绑定它的那个账号。")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .cjkParagraph(11, target: 1.55)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            field("邮箱") {
                // One plain field: splitting the address across a picker broke
                // password-manager autofill for zero gain.
                TextField("name@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
            }

            field("密码") {
                SecureField("", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit { submit() }
            }

            field("国家或地区") {
                Picker("", selection: $country) {
                    Section("常用") {
                        ForEach(AnkerRegion.common) { Text($0.label).tag($0.code) }
                    }
                    Section("其他") {
                        ForEach(AnkerRegion.others) { Text($0.label).tag($0.code) }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack(alignment: .top, spacing: Space.s) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.textTertiary)
                Text(serverHint)
                    .font(Typo.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .cjkParagraph(11, target: 1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.signInError {
                HStack(alignment: .top, spacing: Space.s) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                    Text(error)
                        .font(Typo.caption)
                        .foregroundStyle(Palette.dangerText)
                        .cjkParagraph(11, target: 1.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: model.signInError)
    }

    private var serverHint: String {
        let region = AnkerRegion.named(country)
        let host = region?.serverHost ?? "ankerpower-api-eu.anker.com"
        return L10n.format(
            "%@ 对应 %@。选错国家会直接登录失败——不确定时，对照 Anker 密码重置邮件里的链接域名。",
            country,
            host
        )
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            label("密码只用于这一次登录请求，不保存、不记录、不重用。")
            label("只保留账号 ID，不保留任何能访问账号的凭据。")
            label("这是本应用唯一的一次联网；之后监控充电器全程离线。")
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous).fill(Palette.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.cardInner, style: .continuous)
                .strokeBorder(Palette.stroke, lineWidth: Stroke.hairline)
        )
    }

    private func label(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 10))
                .foregroundStyle(Palette.ok)
            Text(L10n.text(text))
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .cjkParagraph(11, target: 1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if model.isSigningIn {
                ProgressView().controlSize(.small)
                Text("正在登录…").font(Typo.caption).foregroundStyle(Palette.textTertiary)
            }
            Spacer()
            Button("取消") {
                // A slow login must not outlive the sheet and silently rebuild
                // the session later — cancel travels into URLSession.
                loginTask?.cancel()
                model.clearSignInError()
                dismiss()
            }
            .buttonStyle(CharkerActionButtonStyle(emphasis: .quiet))
            .keyboardShortcut(.cancelAction)
            Button("登录") { submit() }
                .buttonStyle(CharkerActionButtonStyle(emphasis: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
        .animation(.easeOut(duration: 0.15), value: model.isSigningIn)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: Space.m) {
            Text(L10n.text(title))
                .font(Typo.body)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 76, alignment: .leading)
            content().font(Typo.body)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        loginTask = Task {
            if await model.signIn(email: address, password: password, country: country) {
                password = ""
                dismiss()
            }
        }
    }
}
