import Foundation

/// Add to NativeChecks with: SetupChecks.run { expect($0, $1) }
/// These checks exercise only value types, never system permission APIs.
enum SetupChecks {
    static func run(expect: (Bool, String) -> Void) {
        var state = SetupReadiness()
        expect(SetupStep.allCases.count == 3, "setup has exactly three groups")
        expect(state.nextStep == .screen && !state.isReady, "new setup starts with screen access")
        state.screen = true
        expect(state.nextStep == .accessibility, "screen grant advances to accessibility")
        state.accessibility = true
        expect(state.nextStep == .voice, "accessibility grant advances to voice")
        expect(state.voiceAction == .requestPermission, "voice groups microphone and speech requests")
        state.microphone = .allowed
        expect(state.voiceAction == .requestPermission && !state.voiceReady, "microphone alone does not complete voice")
        state.speech = .allowed
        state.recognizerExists = true
        state.speechService = true
        expect(state.voiceAction == .dictationSettings && !state.voiceReady, "local assets are part of the voice group")
        state.localModel = true
        expect(state.isReady && state.nextStep == nil, "all grants and local model enable start")
        expect(SetupStep.allCases.allSatisfy(state.isComplete), "each complete group gets a checkmark")
        state.microphone = .denied
        expect(state.nextStep == .voice && state.voiceAction == .microphoneSettings, "revoked microphone returns to its setup action")
        state.microphone = .allowed
        state.speech = .denied
        expect(state.voiceAction == .speechSettings, "denied speech goes to the right system pane")
        state.speech = .restricted
        expect(state.voiceAction == .restricted && !state.isReady, "restricted access never looks ready")
        state.speech = .allowed
        state.localModel = false
        state.requiresLocalModel = false
        expect(state.voiceReady, "explicit advanced online choice does not require local model")
        state.requiresLocalModel = true
        expect(!state.voiceReady, "local-only choice cannot silently fall back online")
        state.localModel = true
        state.speechService = false
        expect(state.voiceAction == .checkAgain && !state.isReady, "temporary service outage retains voice setup")
        state.speechService = true
        state.screen = false
        expect(state.nextStep == .screen, "screen revocation is reflected even after prior completion")
        state.screen = true
        state.accessibility = false
        expect(state.nextStep == .accessibility, "accessibility revocation is reflected after prior completion")
        var recovery = SetupRecoveryState()
        expect(recovery.screenAction == .requestPermission, "first setup requests screen permission")
        expect(recovery.secondaryScreenAction == nil, "new setup does not offer an unnecessary restart")
        recovery.screenWasRequested = true
        expect(recovery.screenAction == .openSettings, "new request leads to settings before restart")
        recovery.screenSettingsOpened = true
        expect(recovery.screenAction == .restart, "return from settings offers restart instead of a settings loop")
        expect(recovery.secondaryScreenAction == .openSettings, "restart keeps screen settings available if access is still off")
        recovery.restartedThisBuild = true
        expect(recovery.screenAction == .repairSettings, "a failed restart leads to repair rather than endless restarts")
        expect(recovery.secondaryScreenAction == .restart, "permission repair can always be followed by a fresh restart")
        state.screen = false
        expect(state.nextStep == .screen && !state.isReady, "restart recovery still requires a real screen grant")
        recovery.restartedThisBuild = false
        expect(recovery.screenAction == .restart, "a new build can make one fresh restart attempt")
    }
}
