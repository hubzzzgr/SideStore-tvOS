import SwiftUI

struct OnboardingView: View {
    var onFinish: (() -> Void)? = nil
    var body: some View {
        NavigationStack {
            AppleTVSetupView().toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SwiftUI.Button("Continue") {
                        UserDefaults.standard.hasCompletedOnboarding = true
                        onFinish?()
                    }
                }
            }
        }
    }
}
