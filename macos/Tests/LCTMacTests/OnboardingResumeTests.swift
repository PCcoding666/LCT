import XCTest
@testable import LCTMac

/// Guards the onboarding resume contract: before the setup flow triggers an
/// app restart (required for screen-recording permission to take effect), the
/// current step is persisted; on the next launch the view consumes it exactly
/// once and lands back on the same step.
final class OnboardingResumeTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        let suite = "OnboardingResumeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        return defaults
    }

    func testOnboardingResume_SavedStep_ConsumeReturnsItOnce() throws {
        let defaults = try makeDefaults()
        OnboardingResumeStore.save(stepID: "permissions", defaults: defaults)

        XCTAssertEqual(
            OnboardingResumeStore.consume(defaults: defaults),
            "permissions",
            "consume must return the saved step id"
        )
        XCTAssertNil(
            OnboardingResumeStore.consume(defaults: defaults),
            "consume must clear the key so a stale step cannot trap the setup flow"
        )
    }

    func testOnboardingResume_NoSavedStep_ConsumeReturnsNil() throws {
        let defaults = try makeDefaults()
        XCTAssertNil(OnboardingResumeStore.consume(defaults: defaults))
    }

    @MainActor
    func testSetupStep_RawValue_RoundTripsThroughResumeStore() throws {
        let defaults = try makeDefaults()
        for step in [WelcomeView.SetupStep.permissions, .complete, .downloadingModel] {
            OnboardingResumeStore.save(stepID: step.rawValue, defaults: defaults)
            let restored = OnboardingResumeStore.consume(defaults: defaults)
            XCTAssertEqual(
                WelcomeView.SetupStep(rawValue: restored ?? ""),
                step,
                "every setup step must survive the save/consume round trip"
            )
        }
    }

    @MainActor
    func testSetupStep_UnknownResumeValue_DoesNotMapToAStep() throws {
        let defaults = try makeDefaults()
        OnboardingResumeStore.save(stepID: "not-a-real-step", defaults: defaults)
        let restored = OnboardingResumeStore.consume(defaults: defaults)
        XCTAssertNil(
            WelcomeView.SetupStep(rawValue: restored ?? ""),
            "an unrecognized saved value must be ignored, not crash or mis-route"
        )
    }

    @MainActor
    func testSetupStep_RawValues_AreStableIdentifiers() {
        XCTAssertEqual(WelcomeView.SetupStep.welcome.rawValue, "welcome")
        XCTAssertEqual(WelcomeView.SetupStep.permissions.rawValue, "permissions")
        XCTAssertEqual(WelcomeView.SetupStep.complete.rawValue, "complete")
    }
}
