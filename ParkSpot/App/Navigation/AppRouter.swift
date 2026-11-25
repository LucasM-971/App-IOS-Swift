// AppRouter.swift
// Central navigation state – drives RootView switching

import SwiftUI
import Combine

enum AppRoute: Equatable {
    case onboarding
    case auth
    case signedOutConfirmation
    case emailConfirmation(email: String)
    case emailVerifiedSuccess
    case main
}

enum AuthEntryMode {
    case signIn
    case signUp
}

final class AppRouter: ObservableObject {
    @Published var currentRoute: AppRoute = .onboarding
    @Published var canReturnFromAuthToMain: Bool = false
    @Published var authEntryMode: AuthEntryMode = .signIn

    func navigateTo(_ route: AppRoute) {
        if route != .auth {
            canReturnFromAuthToMain = false
            authEntryMode = .signIn
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            currentRoute = route
        }
    }

    func navigateToAuthFromSettings(mode: AuthEntryMode = .signIn) {
        canReturnFromAuthToMain = true
        authEntryMode = mode
        withAnimation(.easeInOut(duration: 0.3)) {
            currentRoute = .auth
        }
    }

    func navigateToSignedOutConfirmation() {
        canReturnFromAuthToMain = false
        withAnimation(.easeInOut(duration: 0.3)) {
            currentRoute = .signedOutConfirmation
        }
    }

    func navigateToEmailConfirmation(email: String) {
        canReturnFromAuthToMain = false
        withAnimation(.easeInOut(duration: 0.3)) {
            currentRoute = .emailConfirmation(email: email)
        }
    }

    func navigateToEmailVerifiedSuccess() {
        canReturnFromAuthToMain = false
        withAnimation(.easeInOut(duration: 0.3)) {
            currentRoute = .emailVerifiedSuccess
        }
    }

    func returnToMainFromAuth() {
        canReturnFromAuthToMain = false
        authEntryMode = .signIn
        withAnimation(.easeInOut(duration: 0.3)) {
            currentRoute = .main
        }
    }
}
