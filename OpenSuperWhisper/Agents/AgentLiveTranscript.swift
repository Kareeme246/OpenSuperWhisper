import AppKit
import SwiftUI

/// The text in the folded reply bar while a reply is dictated: "Listening…" until words come in,
/// then the live transcript, as the recording bubble shows it. The panel hides the bubble for its
/// own takes, so without this a user with live text on saw their words nowhere until the take
/// ended.
struct AgentListeningLine: View {
    let label: String

    @ObservedObject private var streaming = StreamingTranscriptionController.shared

    /// The bubble's own rule: live text is on and the engine streams. When the stream could not
    /// start for this take, nothing comes in and the label stays.
    private var caption: AgentLiveCaption? {
        guard IndicatorViewModel.shouldUseLiveStreaming else { return nil }
        return AgentLiveCaption(confirmed: streaming.confirmedText, volatile: streaming.volatileText)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let caption {
                AgentLiveTranscript(caption: caption)
                    .transition(.opacity)
            } else {
                Text(label)
                    .scaledFont(size: 14)
                    .foregroundColor(STheme.hint)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: caption == nil)
    }
}

/// The live transcript in the bar's own height: the newest words on the last line, older ones
/// pushed up and out under a short fade, the way the bubble's caption scrolls. It never grows
/// the bar; a larger text size shows one line instead of two.
struct AgentLiveTranscript: View {
    let caption: AgentLiveCaption

    @Environment(\.textScaleFactor) private var scale
    /// Whether the words run past what is shown, so the top edge fades only when something is
    /// actually cut there.
    @State private var overflows = false

    static let fontSize: CGFloat = 13

    private var lineHeight: CGFloat { AgentLiveCaption.lineHeight(pointSize: Self.fontSize * scale) }
    private var lines: Int { AgentLiveCaption.visibleLines(lineHeight: lineHeight, room: AgentRecordingControls.size) }
    private var maxHeight: CGFloat { lineHeight * CGFloat(lines) }

    var body: some View {
        (Text(caption.confirmed).foregroundColor(STheme.textBright)
            + Text(caption.separator)
            + Text(caption.volatile).foregroundColor(STheme.hint))
            .scaledFont(size: Self.fontSize)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                overflows = height > maxHeight + 0.5
            }
            .frame(maxHeight: maxHeight, alignment: .bottom)
            // Its own height up to the cap, as in the bubble: otherwise a first single line sits
            // at the bottom of an empty second one, off centre against the controls.
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            // SwiftUI's line spacing is not quite the font's, so the descenders of the line that
            // scrolled away peek over the top edge. A short fade hides them.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: overflows ? (lineHeight * 0.3).rounded() : 0)
                    Color.black
                }
            }
            // Read as one thing when VoiceOver reaches it, rather than announced word by word as
            // the stream rewrites it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Live transcription"))
            .accessibilityValue(Text(verbatim: caption.spoken))
    }
}

/// What the reply bar shows of the live transcript: the confirmed words, then the tail the engine
/// may still rewrite, cut to the end of a long take.
struct AgentLiveCaption: Equatable {
    let confirmed: String
    let volatile: String

    /// Several times what the bar's two lines hold, so a long take is not laid out whole on every
    /// word: only its end is ever on screen.
    static let characterLimit = 240
    static let maxLines = 2

    /// Nil when nothing has been heard yet, so the bar keeps saying it is listening.
    init?(confirmed: String, volatile: String, limit: Int = characterLimit) {
        let confirmed = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let volatile = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmed.isEmpty || !volatile.isEmpty else { return nil }
        self.volatile = Self.tail(of: volatile, limit: limit)
        let room = limit - self.volatile.count - (self.volatile.isEmpty ? 0 : 1)
        self.confirmed = Self.tail(of: confirmed, limit: max(0, room))
    }

    var separator: String { confirmed.isEmpty || volatile.isEmpty ? "" : " " }
    var spoken: String { confirmed + separator + volatile }

    /// The end of `text`, at most `limit` characters, starting on a whole word unless a single
    /// word is longer than the limit.
    static func tail(of text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let start = text.index(text.endIndex, offsetBy: -limit)
        if start == text.startIndex || text[text.index(before: start)].isWhitespace {
            return String(text[start...]).trimmingCharacters(in: .whitespaces)
        }
        let cut = text[start...]
        guard let space = cut.firstIndex(where: \.isWhitespace) else { return String(cut) }
        return String(cut[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How many lines fit the row without making it taller, two at most and never none.
    static func visibleLines(lineHeight: CGFloat, room: CGFloat) -> Int {
        guard lineHeight > 0 else { return maxLines }
        return min(maxLines, max(1, Int((room / lineHeight).rounded(.down))))
    }

    /// The system font's line height at that size, the one the bubble's caption is cut to.
    static func lineHeight(pointSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: pointSize)
        return ceil(font.ascender - font.descender + font.leading)
    }
}
