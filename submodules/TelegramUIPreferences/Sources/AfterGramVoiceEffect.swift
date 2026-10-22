import Foundation
import SwiftSignalKit

/// User-selected on-device effect applied to newly recorded voice messages.
public enum AfterGramVoiceEffect: Int, CaseIterable, Equatable {
    case off = 0
    case radio = 1
    case robot = 2
    case bass = 3

    public static let userDefaultsKey = "AfterGramVoiceMessageEffect"

    private static let selectionPromise = ValuePromise<AfterGramVoiceEffect>(AfterGramVoiceEffect.selectedFromDefaults, ignoreRepeated: true)

    private static var selectedFromDefaults: AfterGramVoiceEffect {
        return AfterGramVoiceEffect(rawValue: UserDefaults.standard.integer(forKey: userDefaultsKey)) ?? .off
    }

    public static var selection: Signal<AfterGramVoiceEffect, NoError> {
        return selectionPromise.get()
    }

    public static func updateSelection(_ effect: AfterGramVoiceEffect) {
        UserDefaults.standard.set(effect.rawValue, forKey: userDefaultsKey)
        selectionPromise.set(effect)
    }

    public static var selected: AfterGramVoiceEffect {
        return selectedFromDefaults
    }
}
