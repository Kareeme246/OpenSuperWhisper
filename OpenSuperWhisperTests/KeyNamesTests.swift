import KeyboardShortcuts
import XCTest

@testable import OpenSuperWhisper

/// The names written under the onboarding cards' caps: one per cap, in the view's language.
@MainActor
final class KeyNamesTests: XCTestCase {
    private let english = Locale(identifier: "en")
    private let french = Locale(identifier: "fr")

    private func names(_ trigger: RecordingTrigger, _ locale: Locale) -> [String] {
        trigger.namedKeys(locale: locale).map(\.name)
    }

    private func caps(_ trigger: RecordingTrigger) -> [String] {
        trigger.namedKeys(locale: english).map(\.cap)
    }

    func testRightOptionIsOneCapNamedWithItsSide() {
        let trigger = RecordingTrigger.modifier(.rightOption)
        XCTAssertEqual(caps(trigger), ["⌥"])
        XCTAssertEqual(names(trigger, english), ["Right Option"])
        XCTAssertEqual(names(trigger, french), ["Option droite"])
    }

    func testEverySidedModifierLosesItsGlyphButKeepsItsSide() {
        XCTAssertEqual(names(.modifier(.leftCommand), french), ["Commande gauche"])
        XCTAssertEqual(names(.modifier(.rightControl), english), ["Right Control"])
        XCTAssertEqual(names(.modifier(.leftShift), english), ["Left Shift"])
        XCTAssertEqual(names(.modifier(.fn), french), ["Fonction"])
    }

    func testACombinationNamesEachModifierThenTheKey() {
        let trigger = RecordingTrigger.keyCombo(.init(.d, modifiers: [.control, .option]))
        XCTAssertEqual(caps(trigger), ["⌃", "⌥", "D"])
        XCTAssertEqual(names(trigger, english), ["Control", "Option", "D key"])
        XCTAssertEqual(names(trigger, french), ["Contrôle", "Option", "Touche D"])
    }

    func testShiftAndCommandInACombination() {
        let trigger = RecordingTrigger.keyCombo(.init(.k, modifiers: [.shift, .command]))
        XCTAssertEqual(caps(trigger), ["⇧", "⌘", "K"])
        XCTAssertEqual(names(trigger, french), ["Maj", "Commande", "Touche K"])
    }

    func testTheDefaultCombinationNamesTheLayoutsKey() {
        let iso = KeyboardLayoutInfo(labels: [50: "<"], physicalType: .iso)
        let keys = OnboardingShortcutLabel.combinationKeys(nil, layout: iso, locale: french)
        XCTAssertEqual(keys.map(\.cap), ["⌥", "<"])
        XCTAssertEqual(keys.map(\.name), ["Option", "Inférieur à"])
        let ansi = OnboardingShortcutLabel.combinationKeys(nil, layout: nil, locale: english)
        XCTAssertEqual(ansi.map(\.name), ["Option", "Grave accent"])
    }

    func testSpecialKeysAreNamedNotSpelled() {
        let escape = RecordingTrigger.keyCombo(.init(.escape, modifiers: [.control]))
        XCTAssertEqual(caps(escape), ["⌃", "Esc"])
        XCTAssertEqual(names(escape, french), ["Contrôle", "Échap"])
        let space = RecordingTrigger.keyCombo(.init(.space, modifiers: [.option]))
        XCTAssertEqual(names(space, french).last, "Barre d'espace")
        let arrow = RecordingTrigger.keyCombo(.init(.leftArrow, modifiers: [.command]))
        XCTAssertEqual(names(arrow, english).last, "Left Arrow")
    }

    func testAFunctionKeyAlone() {
        let trigger = RecordingTrigger.keyCombo(.init(.f5))
        XCTAssertEqual(caps(trigger), ["F5"])
        XCTAssertEqual(names(trigger, french), ["Touche de fonction"])
    }

    func testAMouseButtonShowsItsNumberBesideAMouse() {
        let key = RecordingTrigger.mouse(.button4).namedKeys(locale: french)
        XCTAssertEqual(key, [NamedKey(cap: "4", symbol: "computermouse", name: "Bouton 4 (précédent)")])
        XCTAssertEqual(names(.mouse(.middle), english), ["Button 3 (Middle)"])
    }

    func testAChordNamesEveryModifier() throws {
        let chord = try XCTUnwrap(ModifierChord([.command, .option]))
        XCTAssertEqual(caps(.chord(chord)), ["⌥", "⌘"])
        XCTAssertEqual(names(.chord(chord), french), ["Option", "Commande"])
    }

    func testAnUnknownCharacterIsCalledItsKey() {
        XCTAssertEqual(KeyNames.key(cap: "Ç", locale: french).name, "Touche Ç")
        XCTAssertEqual(KeyNames.key(cap: "§", locale: english).name, "Section sign")
    }

    func testALanguageWithoutTheseNamesFallsBackToEnglish() {
        let trigger = RecordingTrigger.keyCombo(.init(.d, modifiers: [.option]))
        XCTAssertEqual(names(trigger, Locale(identifier: "ja")), ["Option", "D key"])
    }

    func testTheGlyphIsCutWhereverATranslationPutsIt() {
        XCTAssertEqual(KeyNames.withoutGlyph("⌥", in: "Rechte ⌥ Wahltaste"), "Rechte Wahltaste")
        XCTAssertEqual(KeyNames.withoutGlyph("⌥", in: "⌥ Option droite"), "Option droite")
        XCTAssertEqual(KeyNames.withoutGlyph("⌥", in: "Right ⌥ Option"), "Right Option")
    }
}
