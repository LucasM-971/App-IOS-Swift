// AuthView.swift
// Login / register with RGPD consent checkbox (obligatoire – RGPD Article 7)

import AuthenticationServices
import SwiftUI

private enum AuthScreen: Hashable {
    case forgotPassword
    case confirmEmailForReset(email: String)
    case resetPassword
}

struct AuthView: View {

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authSession: AuthSession
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var vm: AuthViewModel
    @State private var authPath: [AuthScreen] = []
    @State private var forgotPasswordEmail = ""
    @State private var forgotPasswordMessage: String?
    @State private var forgotPasswordError: String?
    @State private var isSubmittingPasswordResetEmail = false
    @State private var resetPassword = ""
    @State private var resetPasswordConfirmation = ""
    @State private var resetPasswordError: String?
    @State private var isSubmittingNewPassword = false

    init() {
        _vm = StateObject(wrappedValue: AuthViewModel())
    }

    var body: some View {
        NavigationStack(path: $authPath) {
            ScrollView {
                VStack(spacing: 28) {
                    // Logo
                    VStack(spacing: 8) {
                        Image("BrandLogo")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(
                                        Color.white.opacity(colorScheme == .dark ? 0.16 : 0.35),
                                        lineWidth: 1)
                            }
                            .shadow(
                                color: .black.opacity(colorScheme == .dark ? 0.30 : 0.14),
                                radius: 12, y: 6)
                        Text("MosiMap".psLocalized)
                            .font(.title.bold())
                        Text(
                            vm.mode == .signIn
                                ? "Connexion".psLocalized
                                : "Créer un compte".psLocalized
                        )
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)

                    // Form
                    VStack(spacing: 14) {
                        if vm.mode == .signUp {
                            AuthField(
                                label: "Prénom",
                                text: $vm.displayName,
                                icon: "person",
                                textContentType: .givenName,
                                error: nil
                            )
                        }

                        AuthField(
                            label: "Adresse e-mail",
                            text: $vm.email,
                            icon: "envelope",
                            keyboard: .emailAddress,
                            textContentType: .emailAddress,
                            error: nil
                        )

                        AuthField(
                            label: "Mot de passe",
                            text: $vm.password,
                            icon: "lock",
                            isSecure: true,
                            textContentType: vm.mode == .signIn ? .password : .newPassword,
                            error: nil
                        )

                        if vm.mode == .signIn {
                            HStack {
                                Spacer()
                                Button("Mot de passe oublié ?".psLocalized) {
                                    forgotPasswordEmail = vm.email
                                    forgotPasswordError = nil
                                    forgotPasswordMessage = nil
                                    authPath.append(.forgotPassword)
                                }
                                .font(.footnote.weight(.semibold))
                            }
                        }

                        if vm.mode == .signUp {
                            AuthField(
                                label: "Confirmer le mot de passe",
                                text: $vm.confirmPassword,
                                icon: "lock.rotation",
                                isSecure: true,
                                textContentType: .newPassword,
                                error: nil
                            )
                        }

                        // RGPD consent – OBLIGATOIRE pour l'inscription
                        if vm.mode == .signUp {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(isOn: $vm.gdprAccepted) {
                                    Text(
                                        "J'accepte la politique de confidentialité et le traitement de mes données personnelles conformément au RGPD.".psLocalized
                                    )
                                }
                                .font(.footnote)
                                .tint(.green)
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 560)

                    // Error banner
                    if let error = vm.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(.white)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
                            .padding(.horizontal, 24)
                    }

                    // Submit button
                    Button {
                        Task {
                            let attemptedMode = vm.mode
                            let success = await vm.submit()
                            if success {
                                if attemptedMode == .signUp {
                                    let fallbackEmail = vm.email.trimmingCharacters(
                                        in: .whitespacesAndNewlines)
                                    let confirmationEmail = vm.confirmationEmail
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                    router.navigateToEmailConfirmation(
                                        email: confirmationEmail.isEmpty
                                            ? fallbackEmail : confirmationEmail
                                    )
                                } else {
                                    router.navigateTo(.main)
                                }
                            } else if vm.requiresEmailConfirmation {
                                let confirmationEmail = vm.confirmationEmail
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                router.navigateToEmailConfirmation(email: confirmationEmail)
                            }
                        }
                    } label: {
                        Group {
                            if vm.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text(
                                    vm.mode == .signIn
                                        ? "Se connecter".psLocalized
                                        : "Créer mon compte".psLocalized
                                )
                                .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundColor(.white)
                    }
                    .disabled(vm.isLoading)
                    .opacity(vm.isLoading ? 0.8 : 1)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 560)

                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(height: 1)
                            Text("ou".psLocalized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(height: 1)
                        }

                        SignInWithAppleButton(
                            vm.mode == .signIn ? .signIn : .signUp,
                            onRequest: vm.prepareAppleSignInRequest
                        ) { result in
                            Task {
                                let success = await vm.handleAppleSignInCompletion(result)
                                if success { router.navigateTo(.main) }
                            }
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .whiteOutline : .black)
                        .frame(height: 50)
                        .disabled(vm.isLoading)
                    }
                    .padding(.horizontal, 24)
                    .frame(maxWidth: 560)

                    // Mode toggle
                    Button {
                        withAnimation { vm.mode = vm.mode == .signIn ? .signUp : .signIn }
                        vm.error = nil
                        vm.requiresEmailConfirmation = false
                        vm.confirmationEmail = ""
                    } label: {
                        if vm.mode == .signIn {
                            HStack(spacing: 0) {
                                Text("auth.login.no_account".psLocalized)
                                Text("auth.login.create_account".psLocalized)
                                    .bold()
                                    .foregroundColor(Color.blue)
                            }
                        } else {
                            HStack(spacing: 0) {
                                Text("auth.login.already_have_account".psLocalized)
                                Text("auth.login.sign_in".psLocalized)
                                    .bold()
                                    .foregroundColor(Color.blue)
                            }
                        }
                    }
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 40)
                }
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                if router.canReturnFromAuthToMain {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            router.returnToMainFromAuth()
                        } label: {
                            Label("Retour".psLocalized, systemImage: "chevron.left")
                        }
                    }
                }
            }
            .navigationDestination(for: AuthScreen.self) { destination in
                switch destination {
                case .forgotPassword:
                    forgotPasswordPage
                case .confirmEmailForReset(let email):
                    PasswordResetEmailConfirmationCodeView(email: email)
                case .resetPassword:
                    resetPasswordPage
                }
            }
        }
        .onAppear {
            applyEntryModeIfNeeded()
            redirectIfLogged()
            syncRecoveryResetScreen()
        }
        .onChange(of: router.authEntryMode) { _, _ in
            applyEntryModeIfNeeded()
        }
        .onChange(of: authSession.currentUser?.id) { _, _ in
            redirectIfLogged()
        }
        .onChange(of: authSession.needsPasswordResetAfterRecoveryLink) { _, _ in
            syncRecoveryResetScreen()
            redirectIfLogged()
        }
    }

    private var forgotPasswordPage: some View {
        VStack(spacing: 16) {
            Text("auth.forgot_password.title".psLocalized)
                .font(.title3.bold())

            Text("auth.forgot_password.subtitle".psLocalized)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            AuthField(
                label: "Adresse e-mail",
                text: $forgotPasswordEmail,
                icon: "envelope",
                keyboard: .emailAddress,
                textContentType: .emailAddress,
                error: forgotPasswordError
            )

            if let forgotPasswordMessage {
                Text(forgotPasswordMessage)
                    .font(.footnote)
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await sendPasswordResetEmail() }
            } label: {
                Group {
                    if isSubmittingPasswordResetEmail {
                        ProgressView().tint(.white)
                    } else {
                        Text("auth.forgot_password.send_link".psLocalized)
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                .foregroundColor(.white)
            }
            .disabled(isSubmittingPasswordResetEmail)
            .opacity(isSubmittingPasswordResetEmail ? 0.8 : 1)

            Spacer()
        }
        .padding(20)
        .navigationTitle("auth.forgot_password.nav_title".psLocalized)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var resetPasswordPage: some View {
        VStack(spacing: 16) {
            Text("auth.reset_password.title".psLocalized)
                .font(.title3.bold())

            Text("auth.reset_password.subtitle".psLocalized)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            AuthField(
                label: "auth.reset_password.new_password_label",
                text: $resetPassword,
                icon: "lock",
                isSecure: true,
                textContentType: .newPassword,
                error: nil
            )

            AuthField(
                label: "auth.reset_password.confirm_password_label",
                text: $resetPasswordConfirmation,
                icon: "lock.rotation",
                isSecure: true,
                textContentType: .newPassword,
                error: resetPasswordError
            )

            Button {
                Task { await submitRecoveredPasswordUpdate() }
            } label: {
                Group {
                    if isSubmittingNewPassword {
                        ProgressView().tint(.white)
                    } else {
                        Text("auth.reset_password.update_button".psLocalized)
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                .foregroundColor(.white)
            }
            .disabled(isSubmittingNewPassword)
            .opacity(isSubmittingNewPassword ? 0.8 : 1)

            Spacer()
        }
        .padding(20)
        .navigationTitle("auth.reset_password.nav_title".psLocalized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("auth.reset_password.close_button".psLocalized) {
                    authSession.dismissPasswordResetFlow()
                    authPath.removeAll { $0 == .resetPassword }
                }
            }
        }
        .onAppear {
            resetPassword = ""
            resetPasswordConfirmation = ""
            resetPasswordError = nil
        }
    }

    private func applyEntryModeIfNeeded() {
        switch router.authEntryMode {
        case .signIn:
            vm.mode = .signIn
        case .signUp:
            vm.mode = .signUp
        }
        vm.error = nil
    }

    private func redirectIfLogged() {
        guard !authSession.needsPasswordResetAfterRecoveryLink else { return }
        guard authSession.isLogged else { return }
        if router.currentRoute != .main {
            router.navigateTo(.main)
        }
    }

    private func syncRecoveryResetScreen() {
        if authSession.needsPasswordResetAfterRecoveryLink {
            if !authPath.contains(.resetPassword) {
                authPath.append(.resetPassword)
            }
        } else {
            authPath.removeAll { $0 == .resetPassword }
        }
    }

    private func sendPasswordResetEmail() async {
        forgotPasswordError = nil
        forgotPasswordMessage = nil
        isSubmittingPasswordResetEmail = true
        defer { isSubmittingPasswordResetEmail = false }

        do {
            let result = try await authSession.requestPasswordReset(email: forgotPasswordEmail)
            forgotPasswordMessage = result.message
            if result.requiresEmailConfirmationCode {
                let cleanEmail = forgotPasswordEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                authPath.removeAll {
                    if case .confirmEmailForReset = $0 { return true }
                    return false
                }
                authPath.append(.confirmEmailForReset(email: cleanEmail))
            }
        } catch {
            forgotPasswordError = error.localizedDescription
        }
    }

    private func submitRecoveredPasswordUpdate() async {
        resetPasswordError = nil
        isSubmittingNewPassword = true
        defer { isSubmittingNewPassword = false }

        do {
            try await authSession.completePasswordReset(
                newPassword: resetPassword,
                confirmPassword: resetPasswordConfirmation
            )
            authSession.dismissPasswordResetFlow()
            if router.currentRoute != .main {
                router.navigateTo(.main)
            }
        } catch {
            resetPasswordError = error.localizedDescription
        }
    }
}

struct EmailConfirmationView: View {
    let email: String

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var authSession: AuthSession
    @Environment(\.colorScheme) private var colorScheme
    @State private var infoMessage: String?
    @State private var errorMessage: String?
    @State private var code = ""
    @State private var isCheckingVerification = false
    @State private var isSubmittingCode = false
    @State private var didNavigateToVerifiedSuccess = false

    private var cleanEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Spacer(minLength: 24)

                    Image("BrandLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .stroke(
                                    Color.white.opacity(colorScheme == .dark ? 0.16 : 0.35),
                                    lineWidth: 1)
                        }
                        .shadow(
                            color: .black.opacity(colorScheme == .dark ? 0.30 : 0.14), radius: 12, y: 6)

                    Text("Verify your email".psLocalized)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Text(confirmationMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                    VStack(spacing: 16) {
                        AuthField(
                            label: "Verification code",
                            text: $code,
                            icon: "number",
                            keyboard: .numberPad,
                            textContentType: .oneTimeCode,
                            error: errorMessage
                        )

                        Button {
                            Task { await submitCode() }
                        } label: {
                            Group {
                                if isSubmittingCode {
                                    ProgressView().tint(.white)
                                } else {
                                    Text("Verify code".psLocalized)
                                        .font(.system(size: 16, weight: .semibold))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundColor(.white)
                        }
                        .disabled(isSubmittingCode || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity((isSubmittingCode || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 0.8 : 1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                    if let infoMessage {
                        Text(infoMessage)
                            .font(.footnote)
                            .foregroundStyle(.green)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }

                    Spacer()

                    VStack(spacing: 12) {
                        Button {
                            Task {
                                try? await authSession.cancelSignUp(email: email)
                                await authSession.signOut()
                                router.navigateTo(.main)
                            }
                        } label: {
                            Text("Continue without account".psLocalized)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await refreshEmailVerificationStatus(showFeedback: false)

                while !Task.isCancelled && !didNavigateToVerifiedSuccess {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    await refreshEmailVerificationStatus(showFeedback: false)
                }
            }
            .onChange(of: authSession.currentUser?.id) { _, updatedUserId in
                guard updatedUserId != nil else { return }
                navigateToVerifiedSuccessIfNeeded()
            }
        }
    }

    private func submitCode() async {
        errorMessage = nil
        infoMessage = nil
        isSubmittingCode = true
        defer { isSubmittingCode = false }

        do {
            try await authSession.confirmSignUp(email: email, code: code)
            navigateToVerifiedSuccessIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshEmailVerificationStatus(showFeedback: Bool) async {
        guard !isCheckingVerification else { return }
        isCheckingVerification = true
        defer { isCheckingVerification = false }

        do {
            try await authSession.refreshCurrentUserSession()
        } catch {
            // Ignore transport/session refresh errors here: the user may simply not be verified yet.
        }

        if authSession.isLogged {
            navigateToVerifiedSuccessIfNeeded()
        } else if showFeedback {
            infoMessage = "We still can't confirm it yet. Please check your inbox and try again.".psLocalized
        }
    }

    private func navigateToVerifiedSuccessIfNeeded() {
        guard !didNavigateToVerifiedSuccess else { return }
        didNavigateToVerifiedSuccess = true
        router.navigateToEmailVerifiedSuccess()
    }

    private var confirmationMessage: String {
        if cleanEmail.isEmpty {
            return "Your account has been created. We've sent you a confirmation email.".psLocalized
        }

        return String(
            format: "Your account has been created. We've sent a verification code to %@.".psLocalized,
            cleanEmail
        )
    }
}

struct EmailVerifiedSuccessView: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 24)

                Image("BrandLogo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(
                                Color.white.opacity(colorScheme == .dark ? 0.16 : 0.35),
                                lineWidth: 1)
                    }
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.30 : 0.14), radius: 12, y: 6)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.green)

                Text("Your email has been verified".psLocalized)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text("You're now signed in to your account.".psLocalized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Spacer()

                Button {
                    router.navigateTo(.main)
                } label: {
                    Text("Continue".psLocalized)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(UIColor.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct PasswordResetEmailConfirmationCodeView: View {
    let email: String

    @EnvironmentObject private var authSession: AuthSession

    @State private var code = ""
    @State private var infoMessage: String?
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(spacing: 16) {
            Text("auth.confirm_reset.title".psLocalized)
                .font(.title3.bold())

            Text(String(format: "auth.confirm_reset.subtitle %@".psLocalized, email))
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            AuthField(
                label: "auth.confirm_reset.code_label",
                text: $code,
                icon: "number",
                keyboard: .numberPad,
                textContentType: .oneTimeCode,
                error: errorMessage
            )

            if let infoMessage {
                Text(infoMessage)
                    .font(.footnote)
                    .foregroundColor(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await submitCode() }
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView().tint(.white)
                    } else {
                        Text("auth.confirm_reset.validate_button".psLocalized)
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                .foregroundColor(.white)
            }
            .disabled(isSubmitting || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(
                (isSubmitting || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ? 0.8 : 1
            )

            Spacer()
        }
        .padding(20)
        .navigationTitle("auth.confirm_reset.nav_title".psLocalized)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submitCode() async {
        errorMessage = nil
        infoMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let message = try await authSession.confirmEmailCodeBeforePasswordReset(
                email: email,
                code: code
            )
            infoMessage = message
            code = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: – Reusable auth text field
private struct AuthField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    let icon: String
    var keyboard: UIKeyboardType = .default
    var isSecure: Bool = false
    var textContentType: UITextContentType? = nil
    var error: String?
    @State private var revealSecureText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                    .frame(width: 20)

                if isSecure {
                    Group {
                        if revealSecureText {
                            TextField(label, text: $text)
                        } else {
                            SecureField(label, text: $text)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(textContentType)

                    Button {
                        revealSecureText.toggle()
                    } label: {
                        Image(systemName: revealSecureText ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    TextField(label, text: $text)
                        .keyboardType(keyboard)
                        .textContentType(textContentType)
                        .textInputAutocapitalization(keyboard == .emailAddress ? .never : .words)
                        .autocorrectionDisabled()
                }
            }
            .padding(14)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(error != nil ? Color.red : Color.clear, lineWidth: 1.5)
            )

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 4)
            }
        }
    }
}
