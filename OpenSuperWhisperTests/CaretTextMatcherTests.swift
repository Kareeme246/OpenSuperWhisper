import XCTest

@testable import OpenSuperWhisper

/// Covers fitting a dictation to the text around the caret (#163): case, final mark and spaces,
/// for a plain caret and for a selection being replaced. Pure: no field is read.
final class CaretTextMatcherTests: XCTestCase {

    private func fit(_ text: String, _ before: String, _ after: String = "",
                     selected: String = "", nouns: Set<String> = [], adjustCase: Bool = true) -> String {
        CaretTextMatcher.fit(text, into: TextAroundCaret(before: before, selected: selected, after: after),
                             properNouns: nouns, adjustCase: adjustCase)
    }

    // MARK: - The example from the issue

    func testMidSentenceLosesCapitalAndPeriod() {
        XCTAssertEqual(fit("Tomorrow at noon.", "The review is ", " if that suits you."),
                       "tomorrow at noon")
    }

    func testMidSentenceAtTheEndKeepsThePeriod() {
        XCTAssertEqual(fit("Tomorrow at noon.", "The review is "), "tomorrow at noon.")
    }

    // MARK: - Sentence start

    func testEmptyFieldKeepsEverything() {
        XCTAssertEqual(fit("Hello there.", ""), "Hello there.")
    }

    func testAfterAPeriodKeepsTheCapital() {
        XCTAssertEqual(fit("Then we left.", "We ate. "), "Then we left.")
    }

    func testAfterQuestionAndExclamationMarksKeepsTheCapital() {
        XCTAssertEqual(fit("Yes.", "Really? "), "Yes.")
        XCTAssertEqual(fit("Yes.", "Wow! "), "Yes.")
        XCTAssertEqual(fit("Yes.", "Well… "), "Yes.")
    }

    func testAfterALineBreakKeepsTheCapital() {
        XCTAssertEqual(fit("Second line.", "First line,\n"), "Second line.")
    }

    func testAfterAClosedQuotationKeepsTheCapital() {
        XCTAssertEqual(fit("Then he left.", "He said \"stop.\" "), "Then he left.")
        XCTAssertEqual(fit("Then he left.", "(It was late.) "), "Then he left.")
    }

    func testFrenchQuestionMarkWithSpaceStillEndsTheSentence() {
        XCTAssertEqual(fit("Oui.", "Tu viens\u{202F}? "), "Oui.")
    }

    func testAListOrHeadingMarkerStartsASentence() {
        XCTAssertEqual(fit("Buy milk.", "- "), "Buy milk.")
        XCTAssertEqual(fit("Buy milk.", "Groceries:\n* "), "Buy milk.")
        XCTAssertEqual(fit("Buy milk.", "• "), "Buy milk.")
        XCTAssertEqual(fit("Buy milk.", "Notes\n+ "), "Buy milk.")
        XCTAssertEqual(fit("Buy milk.", "# "), "Buy milk.")
        XCTAssertEqual(fit("Buy milk.", "Intro.\n### "), "Buy milk.")
        XCTAssertEqual(fit("Done.", "1) "), "Done.")
        XCTAssertEqual(fit("Done.", "Steps\n12) "), "Done.")
        XCTAssertEqual(fit("Hello.", "> "), "Hello.")
        XCTAssertEqual(fit("Hello.", "Quoting you,\n> > "), "Hello.")
    }

    func testATaskOrANestedMarkerStartsASentence() {
        XCTAssertEqual(fit("Call Anna.", "- [ ] "), "Call Anna.")
        XCTAssertEqual(fit("Call Anna.", "- [x] "), "Call Anna.")
        XCTAssertEqual(fit("Call Anna.", "Plan\n    - "), "Call Anna.")
        XCTAssertEqual(fit("Call Anna.", "> - "), "Call Anna.")
    }

    func testAMarkerWithoutItsSpaceOrAfterTextIsMidSentence() {
        XCTAssertEqual(fit("Release.", "#"), "release.")
        XCTAssertEqual(fit("Aware.", "Very self-"), "aware.")
        XCTAssertEqual(fit("Then left.", "We came - "), "then left.")
        XCTAssertEqual(fit("Then left.", "Item 1) "), "then left.")
    }

    func testAWordAfterAListMarkerIsNotTakenForAProperNoun() {
        XCTAssertEqual(CaretTextMatcher.capitalisedWords(in: "1) Buy milk\n2) Call Anna\n- [x] Pay rent"),
                       ["Anna"])
    }

    // MARK: - Mid-sentence case

    func testAfterACommaLowercases() {
        XCTAssertEqual(fit("But not today.", "I'd love to, "), "but not today.")
    }

    func testAfterAColonLowercases() {
        XCTAssertEqual(fit("Bread and milk.", "We need: "), "bread and milk.")
    }

    func testFrenchMidSentenceLowercasesAccentedLetter() {
        XCTAssertEqual(fit("À demain.", "On se voit "), "à demain.")
    }

    func testKeepsI() {
        XCTAssertEqual(fit("I think so.", "Well, "), "I think so.")
        XCTAssertEqual(fit("I'm late.", "Sorry, "), "I'm late.")
        XCTAssertEqual(fit("I’ll call.", "Fine, "), "I’ll call.")
    }

    func testKeepsAcronymsAndInnerCapitals() {
        XCTAssertEqual(fit("API keys rotate.", "Our "), "API keys rotate.")
        XCTAssertEqual(fit("GitHub is down.", "Apparently "), "GitHub is down.")
    }

    func testKeepsDictionaryTerms() {
        XCTAssertEqual(fit("Kubernetes restarted it.", "Then ", nouns: ["Kubernetes"]),
                       "Kubernetes restarted it.")
        XCTAssertEqual(fit("New York is cold.", "In winter ", nouns: ["New York"]),
                       "New York is cold.")
    }

    func testDictionaryPhraseOnlyProtectsTheWholePhrase() {
        XCTAssertEqual(fit("New ideas came.", "Then ", nouns: ["New York"]), "new ideas came.")
        XCTAssertEqual(fit("Parisian food.", "We had ", nouns: ["Paris"]), "parisian food.")
    }

    func testKeepsWordsCapitalisedMidSentenceInTheField() {
        XCTAssertEqual(fit("Paris is lovely.", "We moved to Paris last year and "),
                       "Paris is lovely.")
        XCTAssertEqual(fit("Paris it is.", "Meet you, ", " and in Paris then"),
                       "Paris it is")
    }

    func testWordCapitalisedOnlyAtASentenceStartInTheFieldIsNotProtected() {
        XCTAssertEqual(fit("Tomorrow at noon.", "Tomorrow works. The review is "),
                       "tomorrow at noon.")
    }

    func testKeepsATitleOrAnInitialBeforeAName() {
        XCTAssertEqual(fit("Mr. Smith came.", "Then "), "Mr. Smith came.")
        XCTAssertEqual(fit("Dr. Who is on.", "Tonight "), "Dr. Who is on.")
        XCTAssertEqual(fit("Mme. Durand appelle.", "Ce matin "), "Mme. Durand appelle.")
        XCTAssertEqual(fit("J. K. Rowling wrote it.", "I think "), "J. K. Rowling wrote it.")
    }

    func testAShortWordEndingASentenceInTheDictationIsStillLowercased() {
        XCTAssertEqual(fit("Yes. Then we go.", "Well, "), "yes. Then we go.")
        XCTAssertEqual(fit("Dr. who knows.", "Ask the "), "dr. who knows.")
    }

    func testKeepsWordsCapitalisedLaterInTheDictation() {
        XCTAssertEqual(fit("Marie said Marie would come.", "And then "),
                       "Marie said Marie would come.")
    }

    func testCapitalisedWordsSkipsSentenceStarts() {
        XCTAssertEqual(CaretTextMatcher.capitalisedWords(in: "Hello. We saw Anna in Rome! Then Bob"),
                       ["Anna", "Rome", "Bob"])
    }

    func testDoesNotLowercaseANonLetterStart() {
        XCTAssertEqual(fit("\"Hello,\" she said.", "Then "), "\"Hello,\" she said.")
        XCTAssertEqual(fit("3 apples.", "We bought "), "3 apples.")
    }

    func testOpeningQuoteMidSentenceLooksThroughToTheSentence() {
        XCTAssertEqual(fit("Fine\" was all.", "He said \""), "fine\" was all.")
        XCTAssertEqual(fit("See below.", "It works ("), "see below.")
    }

    // MARK: - Final mark

    func testDropsQuestionAndExclamationBeforeAContinuation() {
        XCTAssertEqual(fit("Really?", "It was ", " good"), "really")
        XCTAssertEqual(fit("Great!", "It was ", " fun"), "great")
    }

    func testDropsThePeriodBeforePunctuationThatFollows() {
        XCTAssertEqual(fit("Tomorrow.", "Not today but ", ", sorry"), "tomorrow")
        XCTAssertEqual(fit("Tomorrow.", "Not today but ", "."), "tomorrow")
    }

    func testLooksThroughAClosingBracketOrQuoteForTheRestOfTheSentence() {
        XCTAssertEqual(fit("If it's sunny.", "I'll come (", ") tomorrow"), "if it's sunny")
        XCTAssertEqual(fit("Stop.", "He said \"", "\" and left"), "stop")
        XCTAssertEqual(fit("Arrête.", "Il a dit « ", " » et il est parti"), "arrête")
        XCTAssertEqual(fit("Tomorrow.", "(Or ", "), then"), "tomorrow")
    }

    func testKeepsThePeriodWhenANewSentenceFollowsTheClosingMark() {
        XCTAssertEqual(fit("It was late.", "Done. (", ")"), "It was late.")
        XCTAssertEqual(fit("It was late.", "Done. (", ") Then"), "It was late.")
        XCTAssertEqual(fit("Stop.", "He said \"", "\"\nThen"), "stop.")
    }

    func testAnOpeningQuoteAfterTheCaretIsNotLookedThrough() {
        XCTAssertEqual(fit("At noon.", "Meet ", " \"sharp\""), "at noon.")
    }

    func testKeepsThePeriodBeforeANewSentence() {
        XCTAssertEqual(fit("Tomorrow.", "Not today but ", " Then we go."), "tomorrow.")
    }

    func testKeepsThePeriodBeforeALineBreak() {
        XCTAssertEqual(fit("Tomorrow.", "Not today but ", "\nnext"), "tomorrow.")
    }

    func testFrenchSpaceBeforeTheDroppedMarkGoesWithIt() {
        XCTAssertEqual(fit("Vraiment ?", "C'est ", " bizarre"), "vraiment")
        XCTAssertEqual(fit("Vraiment\u{202F}!", "C'est ", " bizarre"), "vraiment")
        XCTAssertEqual(fit("Vraiment\u{00A0}?", "C'est ", " bizarre"), "vraiment")
    }

    func testKeepsEllipsisDoubledMarksAndAbbreviations() {
        XCTAssertEqual(fit("Well...", "It was ", " fine"), "well...")
        XCTAssertEqual(fit("What?!", "It was ", " fine"), "what?!")
        XCTAssertEqual(fit("At 10 a.m.", "Meet ", " sharp"), "at 10 a.m.")
        XCTAssertEqual(fit("Fruit, e.g.", "Buy ", " apples"), "fruit, e.g.")
        XCTAssertEqual(fit("Plan B.", "Go with ", " then"), "plan B.")
    }

    func testANumberIsNotAnInitial() {
        XCTAssertEqual(fit("Level 5.", "I'm at ", " now"), "level 5")
        XCTAssertEqual(fit("Room 3.", "Go to ", ", left"), "room 3")
    }

    func testDoesNotDropAMarkThatIsTheWholeDictation() {
        XCTAssertEqual(fit("?", "What", " now"), "?")
    }

    // MARK: - Spaces

    func testLeadingSpaceAfterAWord() {
        XCTAssertEqual(fit("And then some.", "It rained"), " and then some.")
    }

    func testLeadingSpaceAfterPunctuation() {
        XCTAssertEqual(fit("Then we left.", "We ate."), " Then we left.")
        XCTAssertEqual(fit("But no.", "Yes,"), " but no.")
    }

    func testNoLeadingSpaceAfterSpaceLineBreakOrOpeningMark() {
        XCTAssertEqual(fit("Hi.", "Done. "), "Hi.")
        XCTAssertEqual(fit("Hi.", "Done.\n"), "Hi.")
        XCTAssertEqual(fit("See below.", "It works ("), "see below.")
        XCTAssertEqual(fit("Hello.", "« "), "Hello.")
        XCTAssertEqual(fit("Hello.", "He said “"), "hello.")
    }

    func testStraightQuoteBeforeTheCaretOpensOrClosesByWhatPrecedesIt() {
        XCTAssertEqual(fit("Hello.", "He said \""), "hello.")
        XCTAssertEqual(fit("And left.", "He said \"hi\""), " and left.")
        XCTAssertEqual(fit("Were there.", "The students'"), " were there.")
    }

    func testNoLeadingSpaceAfterAFrenchElision() {
        XCTAssertEqual(fit("Avion.", "J'ai pris l'"), "avion.")
        XCTAssertEqual(fit("Avion.", "J’ai pris l’"), "avion.")
        XCTAssertEqual(fit("Accord.", "Je suis d'"), "accord.")
        XCTAssertEqual(fit("Il pleuve.", "Bien qu'"), "il pleuve.")
        XCTAssertEqual(fit("Ici.", "Jusqu’"), "ici.")
        XCTAssertEqual(fit("Avion.", "L'"), "avion.")
    }

    func testAnApostropheAfterAnyOtherWordStillGetsASpace() {
        XCTAssertEqual(fit("Were there.", "The students’"), " were there.")
        XCTAssertEqual(fit("And left.", "She said 'hi'"), " and left.")
    }

    func testNoLeadingSpaceAfterMentionTagPathOrHyphen() {
        XCTAssertEqual(fit("Marie.", "Thanks @", nouns: ["Marie"]), "Marie.")
        XCTAssertEqual(fit("Release.", "See #"), "release.")
        XCTAssertEqual(fit("Aware.", "Very self-"), "aware.")
    }

    func testNoLeadingSpaceBeforePunctuationThatHangsOnThePreviousWord() {
        XCTAssertEqual(fit(", right?", "It works"), ", right?")
        XCTAssertEqual(fit("\" she said.", "\"Hello"), "\" she said.")
    }

    func testLeadingSpaceBeforeAnOpeningQuote() {
        XCTAssertEqual(fit("\"Hello,\" she said.", "Then"), " \"Hello,\" she said.")
    }

    func testTrailingSpaceOnlyBeforeAWord() {
        XCTAssertEqual(fit("At noon.", "Meet ", "tomorrow"), "at noon ")
        XCTAssertEqual(fit("At noon.", "Meet ", "Then"), "at noon. ")
        XCTAssertEqual(fit("At noon", "Meet ", "(sharp)"), "at noon ")
        XCTAssertEqual(fit("At noon", "Meet ", "\"sharp\""), "at noon ")
        XCTAssertEqual(fit("At noon", "Meet ", "42"), "at noon ")
    }

    func testNoTrailingSpaceAtTheEndOrBeforeSpaceOrPunctuation() {
        XCTAssertEqual(fit("At noon.", "Meet "), "at noon.")
        XCTAssertEqual(fit("At noon.", "Meet ", " tomorrow"), "at noon")
        XCTAssertEqual(fit("At noon", "Meet ", ", ok"), "at noon")
        XCTAssertEqual(fit("At noon", "Meet ", "\" she said"), "at noon")
        XCTAssertEqual(fit("At noon", "Meet ", "\nnext"), "at noon")
    }

    func testReplacesTheUnconditionalSpaceFromPostProcessing() {
        XCTAssertEqual(fit("At noon. ", "Meet "), "at noon.")
        XCTAssertEqual(fit(" Hello there. ", ""), "Hello there.")
    }

    func testBothSpacesInsideAWord() {
        XCTAssertEqual(fit("Very", "It is", "good"), " very ")
    }

    func testNoSpacesAroundChineseOrJapanese() {
        XCTAssertEqual(fit("你好。", "我说"), "你好。")
        XCTAssertEqual(fit("Hello", "我说", "你好"), "hello")
        XCTAssertEqual(fit("こんにちは", "Say"), "こんにちは")
    }

    func testKeepsALeadingOrTrailingLineBreak() {
        XCTAssertEqual(fit("\nNew paragraph.", "End."), "\nNew paragraph.")
        XCTAssertEqual(fit("Last line.\n", "Start ", "more"), "last line.\n")
    }

    func testBlankDictationIsUntouched() {
        XCTAssertEqual(fit("  ", "Word", "word"), "  ")
        XCTAssertEqual(fit("", "Word"), "")
    }

    // MARK: - Languages that capitalise nouns

    func testCaseIsLeftAloneWhenNotAdjusted() {
        XCTAssertEqual(fit("Termin morgen.", "Ich habe den ", adjustCase: false), "Termin morgen.")
        XCTAssertEqual(fit("Termin.", "Ich habe den", " morgen", adjustCase: false), " Termin")
        XCTAssertEqual(fit("termin.", "", " ist gut", selected: "Treffen", adjustCase: false), "termin")
    }

    func testGermanAndLuxembourgishKeepTheirCase() {
        XCTAssertFalse(CaretTextMatcher.adjustsCase(language: "de"))
        XCTAssertFalse(CaretTextMatcher.adjustsCase(language: "de-CH"))
        XCTAssertFalse(CaretTextMatcher.adjustsCase(language: "de_AT"))
        XCTAssertFalse(CaretTextMatcher.adjustsCase(language: "lb"))
        XCTAssertTrue(CaretTextMatcher.adjustsCase(language: "en"))
        XCTAssertTrue(CaretTextMatcher.adjustsCase(language: "fr"))
        XCTAssertTrue(CaretTextMatcher.adjustsCase(language: nil))
    }

    // MARK: - Selection

    func testReplacingACapitalisedSelectionCapitalises() {
        XCTAssertEqual(fit("next week.", "", " is fine.", selected: "Tomorrow"), "Next week")
        XCTAssertEqual(fit("next week.", "Not today. ", "", selected: "Tomorrow"), "Next week.")
    }

    func testReplacingALowercaseSelectionLowercasesEvenAtASentenceStart() {
        XCTAssertEqual(fit("Next week.", "", " is fine.", selected: "tomorrow"), "next week")
        XCTAssertEqual(fit("Next week.", "", "", selected: "tomorrow"), "next week.")
    }

    func testReplacingALowercaseSelectionStillKeepsProperNounsAndI() {
        XCTAssertEqual(fit("Paris.", "See you in ", " then", selected: "london", nouns: ["Paris"]), "Paris")
        XCTAssertEqual(fit("I did.", "", "", selected: "you did"), "I did.")
    }

    func testSelectionKeepsItsEdgeSpaces() {
        XCTAssertEqual(fit("Friday.", "Meet on", "at noon", selected: " monday "), " friday ")
        XCTAssertEqual(fit("Friday", "Meet on ", "at noon", selected: "monday "), "friday ")
    }

    func testSelectionInsideASentenceDropsTheMarkAndSpacesLikeACaret() {
        XCTAssertEqual(fit("Friday.", "Meet on ", " at noon.", selected: "Monday"), "Friday")
        XCTAssertEqual(fit("Friday.", "Meet on", "at noon.", selected: "monday"), " friday ")
    }

    func testSelectionThatIsOnlySpacesIsKeptOnTheLeft() {
        XCTAssertEqual(fit("Hello", "Say", "now", selected: "  "), "  hello ")
    }

    func testSelectionStartingWithANonLetterFallsBackToTheSentence() {
        XCTAssertEqual(fit("Five.", "It costs ", " euros", selected: "4"), "five")
    }
}
