import PhotoSwipeCore
import SwiftUI

@main
struct PhotoSwipeApp: App {
    @State private var environment = AppEnvironment.makeDefault()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                environment.handleBecameActive()
            }
        }
    }
}

/// Aiguillage principal selon l'onboarding et l'autorisation d'accès aux photos.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if !environment.settings.hasCompletedOnboarding || environment.authorization == .notDetermined {
                OnboardingView()
            } else if environment.authorization.allowsReading {
                HomeView()
            } else {
                PhotoAccessDeniedView(authorization: environment.authorization)
            }
        }
        .animation(.default, value: environment.authorization)
        .animation(.default, value: environment.settings.hasCompletedOnboarding)
    }
}
