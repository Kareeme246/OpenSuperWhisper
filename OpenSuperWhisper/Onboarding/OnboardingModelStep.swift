import SwiftUI
import OpenSuperWhisperCore

/// Step 2: the spoken language, then the model the app suggests for it, explained, with the
/// other models and a remote server below. Continue waits for a model on disk (or a server).
/// Where macOS has its own speech model for the language, it comes first and is preselected:
/// nothing to download. Parakeet stays recommended right under it, for its accuracy.
struct OnboardingModelStep: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsGroup("Spoken language") {
                SettingRow("I speak", hint: "The recommendation follows your language.") {
                    languageMenu
                }
                if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                    SettingRow("Asian autocorrect", hint: "Fixes spacing in Chinese, Japanese and Korean text.") {
                        SSwitch(isOn: $viewModel.useAsianAutocorrect)
                    }
                }
            }

            if let apple = binding(for: viewModel.appleSpeechRow) {
                OnboardingModelRow(model: apple, viewModel: viewModel,
                                   explanation: "Apple's own model: fast, private, no account needed.",
                                   tag: ("Built into macOS", .engine))
            }

            if let recommended = binding(for: viewModel.recommendedModel) {
                OnboardingModelRow(model: recommended, viewModel: viewModel,
                                   explanation: explanation(for: recommended.wrappedValue),
                                   tag: ("Recommended", .new))
            }

            section("Other options") {
                ForEach($viewModel.unifiedModels) { $model in
                    if model.id != viewModel.recommendedModel?.id && !model.isAppleSpeech {
                        OnboardingModelRow(model: $model, viewModel: viewModel)
                    }
                }
                remoteOption
            }
        }
    }

    private var languageMenu: some View {
        SMenu(SpokenLanguageName.text(for: viewModel.selectedLanguage, locale: locale)) {
            Picker("", selection: $viewModel.selectedLanguage) {
                ForEach(SpokenLanguageName.sorted(LanguageUtil.availableLanguages, locale: locale),
                        id: \.self) { code in
                    SpokenLanguageName.text(for: code, locale: locale).tag(code)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundColor(STheme.textBright)
            content()
        }
    }

    private func binding(for model: OnboardingUnifiedModel?) -> Binding<OnboardingUnifiedModel>? {
        guard let model, let index = viewModel.unifiedModels.firstIndex(where: { $0.id == model.id })
        else { return nil }
        return $viewModel.unifiedModels[index]
    }

    /// Next to Apple's model, which needs nothing from the app, the case for this one is
    /// accuracy. A reinstall has it on disk already, so it promises no download.
    private func explanation(for model: OnboardingUnifiedModel) -> LocalizedStringKey {
        if viewModel.appleSpeechRow != nil {
            return model.isDownloaded
                ? "More accurate than Apple's model. Runs on this Mac, no account needed."
                : "More accurate than Apple's model. One download, then it runs on this Mac, no account needed."
        }
        switch model.type {
        case .parakeet:
            return "Fast and accurate in your language. Runs on this Mac, no account needed."
        case .whisper, .senseVoice, .appleSpeech:
            return "Understands your language well. Runs on this Mac, no account needed."
        }
    }

    // A remote (OpenAI-compatible) server needs no local model; its endpoint and key are set
    // in Settings once setup is done.
    private var remoteOption: some View {
        Button { viewModel.selectRemote() } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "cloud")
                    .scaledFont(size: 18)
                    .foregroundColor(STheme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use a remote server")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundColor(STheme.textBright)
                    Text("OpenAI-compatible API (Groq, or your own server). Set the endpoint and key in Settings after setup.")
                        .scaledFont(size: 13)
                        .foregroundColor(STheme.hint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                if viewModel.remoteSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 18)
                        .foregroundColor(STheme.accent)
                }
            }
            .onboardingChoice(selected: viewModel.remoteSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(viewModel.remoteSelected ? .isSelected : [])
    }
}

/// One model: what it is, its download and its state. `explanation` marks a highlighted one
/// (the recommended model, Apple's), drawn larger with the reason it is offered and `tag` above
/// its name.
struct OnboardingModelRow: View {
    @Binding var model: OnboardingUnifiedModel
    @ObservedObject var viewModel: OnboardingViewModel
    var explanation: LocalizedStringKey? = nil
    var tag: (label: LocalizedStringKey, kind: SBadgeKind)? = nil
    @State private var showError = false
    @State private var errorMessage = ""

    private var isSelected: Bool { viewModel.selectedModelId == model.id }
    /// Usable as it is: on disk, or Apple's, which macOS provides.
    private var isReady: Bool { model.isDownloaded || model.isAppleSpeech }
    private var isDownloadingThis: Bool {
        viewModel.isDownloading && viewModel.downloadingModelName == model.name
    }
    private var prominent: Bool { explanation != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                if let tag {
                    SBadge(tag.label, kind: tag.kind).padding(.bottom, 4)
                }
                HStack(spacing: 8) {
                    Text(model.name)
                        .scaledFont(size: prominent ? 20 : 15, weight: prominent ? .bold : .semibold)
                        .foregroundColor(STheme.textBright)
                    // Apple's gets no badge: the line under its name says where its language is.
                    if model.isDownloaded {
                        SBadge("Downloaded", kind: .engine)
                    }
                }
                Text(description)
                    .scaledFont(size: 13)
                    .foregroundColor(STheme.hint)
                    .fixedSize(horizontal: false, vertical: true)
                if let explanation {
                    Text(explanation)
                        .scaledFont(size: 14)
                        .foregroundColor(STheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                progress
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            action
        }
        .onboardingChoice(selected: isSelected, padding: prominent ? 20 : 16)
        .contentShape(Rectangle())
        .onTapGesture {
            if isReady && !isSelected { viewModel.selectModel(model) }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    /// Apple's says where its language stands: on this Mac already, or fetched by macOS on
    /// first use. Saying it is there before it is would make the first dictation's wait a
    /// surprise.
    private var description: LocalizedStringKey {
        guard model.isAppleSpeech else { return model.description }
        return viewModel.appleSpeech == .installed
            ? "Already on this Mac for your language. Nothing to download."
            : "macOS downloads your language the first time you dictate. Nothing to download in the app."
    }

    /// A bar once the download reports how far it is, a spinner before that (Parakeet's first
    /// moments, and loading it once fetched).
    @ViewBuilder private var progress: some View {
        if model.downloadProgress > 0 && model.downloadProgress < 1 {
            ProgressView(value: model.downloadProgress)
                .progressViewStyle(.linear)
                .tint(STheme.accent)
                .frame(maxWidth: 280)
                .padding(.top, 6)
        } else if isDownloadingThis {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 6)
        }
    }

    @ViewBuilder private var action: some View {
        if isDownloadingThis {
            Button("Cancel") { viewModel.cancelDownload() }
                .buttonStyle(.sSecondary)
        } else if isReady {
            if isSelected {
                Label("Selected", systemImage: "checkmark")
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundColor(STheme.ok)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(STheme.okBg))
                    .fixedSize()
            } else {
                Button("Select") { viewModel.selectModel(model) }
                    .buttonStyle(.sSecondary)
            }
        } else {
            Button {
                download()
            } label: {
                Label("Download", systemImage: "arrow.down")
            }
            .buttonStyle(SButtonStyle(kind: prominent ? .primary : .secondary))
            .disabled(viewModel.isDownloading)
        }
    }

    private func download() {
        Task {
            do {
                try await viewModel.downloadModel(model)
            } catch is CancellationError {
                // Cancelled by the user: nothing to report.
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

extension View {
    /// The card every onboarding choice sits on: cream with a hairline, accent ring once chosen.
    func onboardingChoice(selected: Bool, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? STheme.accentTint : STheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? STheme.accent : STheme.border, lineWidth: selected ? 2 : 1))
    }
}
