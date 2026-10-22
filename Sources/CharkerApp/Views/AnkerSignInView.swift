import Accessibility
import CharkerCore
import SwiftUI

enum AnkerSignInPurpose {
    case ownerID
    case a2345Cloud
}

/// An explicit Anker sign-in for either the A2687 owner id or the A2345 cloud
/// reader.
struct AnkerSignInView: View {
    @ObservedObject var model: AppModel
    var purpose: AnkerSignInPurpose = .ownerID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var email = ""
    @State private var password = ""
    @State private var country = ""
    @State private var phoneNumber = ""
    @State private var verificationCode = ""
    @State private var sentPhoneNumber: String?
    @State private var isSendingCode = false
    @State private var isSubmitting = false
    @State private var resendAvailableAt: Date?
    @State private var sendTask: Task<Void, Never>?
    @State private var requestGeneration = UUID()
    private let client = AnkerAccountClient()
    @State private var loginTask: Task<Void, Never>?
    @State private var attemptedSubmit = false
    @FocusState private var focus: Field?
    @AccessibilityFocusState private var errorAccessibilityFocused: Bool

    private enum Field { case email, password, phone, code }

    private var isChina: Bool { country == "CN" }
    private var isBusy: Bool { model.isSigningIn || isSendingCode || isSubmitting }
    private var normalizedPhone: String { phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSubmit: Bool {
        validationMessage == nil && !isBusy
    }

    private var validationMessage: String? {
        if isChina {
            if !AnkerAccountClient.isValidPhoneNumber(normalizedPhone) { return L10n.text("请输入 11 位中国大陆手机号") }
            if sentPhoneNumber != normalizedPhone { return L10n.text("请先获取短信验证码") }
            if !AnkerAccountClient.isValidVerificationCode(verificationCode) { return L10n.text("请输入 6 位短信验证码") }
            return nil
        }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty { return L10n.text("请输入邮箱") }
        if !address.contains("@") || address.count < 5 || !address.contains(".") {
            return L10n.text("请输入有效的邮箱地址")
        }
        if password.isEmpty { return L10n.text("请输入密码") }
        if country.count != 2 { return L10n.text("请选择国家或地区") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header
            form
            Divider().overlay(Palette.stroke)
            footer
        }
        .padding(Space.xl)
        .frame(width: 440)
        .background(Palette.surface)
        .tint(Palette.accent)
        .onAppear {
            model.clearSignInError()
            if country.isEmpty { country = model.defaultCountryCode }
            // Focus set directly in onAppear races the sheet's key-window
            // handshake and frequently lands nowhere.
            DispatchQueue.main.async { focus = isChina ? .phone : .email }
        }
        .onChange(of: model.signInError) { _, error in
            guard error != nil else {
                errorAccessibilityFocused = false
                return
            }
            // Keep keyboard focus in the credential field so correction is
            // immediate. Moving VoiceOver focus to the entered error announces
            // it once; posting the same Announcement as well caused a duplicate.
            DispatchQueue.main.async {
                errorAccessibilityFocused = true
            }
        }
        .onDisappear {
            cancelRequests()
            password = ""
            verificationCode = ""
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(L10n.text(
                purpose == .a2345Cloud ? "连接 Anker Prime 250W" : "用 Anker 账号获取 ID"
            ))
                .font(Typo.title)
                .foregroundStyle(Palette.textPrimary)
            Text("用绑定这台充电器的 Anker 账号登录。")
                .font(Typo.caption)
                .foregroundStyle(Palette.textSecondary)
                .cjkParagraph(11, target: 1.55)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            field("国家或地区") {
                Picker("", selection: countryBinding) {
                    Section("常用") {
                        ForEach(AnkerRegion.common) { Text($0.label).tag($0.code) }
                    }
                    Section("其他") {
                        ForEach(AnkerRegion.others) { Text($0.label).tag($0.code) }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel(Text(L10n.text("国家或地区")))
            }

            if isChina {
                phoneFields
            } else {
                field("邮箱") {
                    // One plain field: splitting the address across a picker broke
                    // password-manager autofill for zero gain.
                    TextField("name@example.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .accessibilityLabel(Text(L10n.text("邮箱")))
                        .accessibilityHint(Text(emailAccessibilityHint))
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                }

                field("密码") {
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .accessibilityLabel(Text(L10n.text("密码")))
                        .accessibilityHint(Text(passwordAccessibilityHint))
                        .focused($focus, equals: .password)
                        .onSubmit { submit() }
                }
            }

            if !isChina {
                note("国家或地区选错会登录失败。", symbol: "info.circle")
                note("密码不会保存。", symbol: "lock")
            }

            if attemptedSubmit, let validationMessage {
                validationNotice(validationMessage)
                    .transition(errorTransition)
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
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(error))
                .accessibilityFocused($errorAccessibilityFocused)
                .transition(errorTransition)
            }
        }
        .animation(Motion.reduced(Motion.ui, reduceMotion), value: model.signInError)
    }

    private var emailAccessibilityHint: String {
        guard attemptedSubmit,
              validationMessage == L10n.text("请输入邮箱")
                || validationMessage == L10n.text("请输入有效的邮箱地址") else {
            return L10n.text("输入绑定 Anker 账号的邮箱")
        }
        return validationMessage ?? ""
    }

    private var passwordAccessibilityHint: String {
        attemptedSubmit && validationMessage == L10n.text("请输入密码")
            ? L10n.text("请输入密码")
            : L10n.text("输入 Anker 账号密码；密码不会保存")
    }

    private var errorTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -4))
    }

    private func validationNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Palette.warn)
                .accessibilityHidden(true)
            Text(message)
                .font(Typo.caption)
                .foregroundStyle(Palette.warnText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message))
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(Palette.textTertiary)
            Text(L10n.text(text))
                .font(Typo.caption)
                .foregroundStyle(Palette.textTertiary)
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
                cancelRequests()
                model.clearSignInError()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(L10n.text(isChina && sentPhoneNumber != normalizedPhone ? "获取验证码" : "登录")) {
                primaryAction()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
            .accessibilityHint(Text(validationMessage ?? L10n.text("登录 Anker 账号")))
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

    private var phoneFields: some View {
        Group {
            field("手机号") {
                TextField("13800138000", text: phoneBinding)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.telephoneNumber)
                    .accessibilityLabel(Text(L10n.text("手机号")))
                    .focused($focus, equals: .phone)
                    .onSubmit {
                        if sentPhoneNumber == normalizedPhone {
                            focus = .code
                        } else {
                            primaryAction()
                        }
                    }
            }
            field("验证码") {
                HStack {
                    TextField("", text: $verificationCode)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.oneTimeCode)
                        .accessibilityLabel(Text(L10n.text("验证码")))
                        .focused($focus, equals: .code)
                        .onSubmit { submit() }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil((resendAvailableAt ?? .distantPast).timeIntervalSince(context.date))))
                        Button {
                            sendCode()
                        } label: {
                            if isSendingCode {
                                Text(L10n.text("正在发送…"))
                            } else if remaining > 0 {
                                Text(L10n.format("%d 秒后重发", remaining))
                            } else {
                                Text(L10n.text("获取验证码"))
                            }
                        }
                        .disabled(isBusy || remaining > 0 || !AnkerAccountClient.isValidPhoneNumber(normalizedPhone))
                    }
                }
            }
        }
    }

    private var countryBinding: Binding<String> {
        Binding(get: { country }, set: { value in
            guard country != value else { return }
            cancelRequests()
            country = value
            verificationCode = ""
            password = ""
            sentPhoneNumber = nil
            attemptedSubmit = false
            model.clearSignInError()
            focus = value == "CN" ? .phone : .email
        })
    }

    private var phoneBinding: Binding<String> {
        Binding(get: { phoneNumber }, set: { value in
            guard phoneNumber != value else { return }
            cancelRequests()
            phoneNumber = value
            verificationCode = ""
            sentPhoneNumber = nil
            attemptedSubmit = false
            model.clearSignInError()
        })
    }

    private func primaryAction() {
        guard !isBusy else { return }
        if isChina, sentPhoneNumber != normalizedPhone {
            if !AnkerAccountClient.isValidPhoneNumber(normalizedPhone) {
                attemptedSubmit = true
                focus = .phone
            } else {
                sendCode()
            }
        } else {
            submit()
        }
    }

    private func cancelRequests() {
        requestGeneration = UUID()
        loginTask?.cancel()
        sendTask?.cancel()
        isSendingCode = false
        isSubmitting = false
    }

    private func sendCode() {
        guard isChina, !isBusy, AnkerAccountClient.isValidPhoneNumber(normalizedPhone),
              (resendAvailableAt ?? .distantPast) <= .now else { return }
        let phone = normalizedPhone
        let generation = requestGeneration
        isSendingCode = true
        // Cancellation and transport errors cannot prove that the server did
        // not send an SMS. Reserve the window before starting the request.
        resendAvailableAt = .now.addingTimeInterval(60)
        verificationCode = ""
        sentPhoneNumber = nil
        sendTask = Task {
            let success = await model.sendPhoneVerificationCode(phone, client: client)
            guard !Task.isCancelled, requestGeneration == generation else { return }
            isSendingCode = false
            if success {
                sentPhoneNumber = phone
                resendAvailableAt = .now.addingTimeInterval(60)
                focus = .code
            }
        }
    }

    private func submit() {
        attemptedSubmit = true
        guard canSubmit else {
            if isChina {
                focus = AnkerAccountClient.isValidPhoneNumber(normalizedPhone) ? .code : .phone
            } else {
                let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
                focus = address.isEmpty || !address.contains("@") || !address.contains(".") ? .email : .password
            }
            return
        }
        let generation = requestGeneration
        let selectedCountry = country
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = normalizedPhone
        let code = verificationCode
        let enteredPassword = password
        isSubmitting = true
        loginTask = Task {
            let success: Bool
            if selectedCountry == "CN" {
                success = await model.signIn(
                    phoneNumber: phone, verificationCode: code, client: client,
                    connectA2345: purpose == .a2345Cloud
                )
            } else {
                success = await model.signIn(
                    email: address, password: enteredPassword, country: selectedCountry,
                    connectA2345: purpose == .a2345Cloud
                )
            }
            guard !Task.isCancelled, requestGeneration == generation else { return }
            isSubmitting = false
            if success {
                password = ""
                verificationCode = ""
                dismiss()
            }
        }
    }
}
