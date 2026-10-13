import SwiftUI

/// The sidebar's Feedback popover: the same three links as Help & what's new, one click from
/// anywhere in the main window. Picking one opens it in the browser and closes the menu.
struct FeedbackMenu: View {
    var onPick: () -> Void = {}
    @Environment(\.textScaleFactor) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Feedback")
                    .scaledFont(size: 15, weight: .bold)
                    .foregroundColor(STheme.textBright)
                Text("Every report makes the app more stable.")
                    .scaledFont(size: 12)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
            ForEach(FeedbackLink.all) { link in
                FeedbackMenuRow(link: link) {
                    NSWorkspace.shared.open(link.url)
                    onPick()
                }
            }
        }
        .padding(8)
        // Wider with the text, as the sidebar is, so the subtitles don't wrap any further.
        .frame(width: 360 * min(max(textScale, 1), 1.45))
        .background(STheme.cardBg)
        .onExitCommand(perform: onPick)
    }
}

/// One link of the menu: icon, title, one sentence, and the ↗ that says it leaves the app.
private struct FeedbackMenuRow: View {
    let link: FeedbackLink
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: link.symbol)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundColor(STheme.accent)
                    .frame(width: 22)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title)
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundColor(STheme.textBright)
                    Text(link.subtitle)
                        .scaledFont(size: 12)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundColor(STheme.hint)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? STheme.accentTint : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
