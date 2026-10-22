import DictationLibrary
import SwiftUI

struct TranscriptionSettingsSection: View {
    @Bindable var settings: TranscriptionSettingsStore
    let library: SharedDictationLibrary?
    @State private var confirmsAccountAssignment = false
    @State private var confirmsLocalRelease = false
    @State private var localReleaseAccount: DictationAccountSession?
    @State private var assignmentAccount: DictationAccountSession?

    var body: some View {
        Section {
            Picker("Provider", selection: providerSelection.nativeSelectionFeedback()) {
                ForEach(TranscriptionProvider.allCases) { provider in
                    Text(provider.name).tag(provider)
                }
            }
            .drillDownPickerStyle()
            .disabled(library?.isSavingSettings == true)

            Picker("Model", selection: modelSelection.nativeSelectionFeedback()) {
                ForEach(selectedModel.provider.models) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                        Text(captureDescription(model.capture))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(model)
                }
            }
            .drillDownPickerStyle()
            .disabled(library?.isSavingSettings == true)

            if let library, library.isEnabled, let profile = library.profile {
                Picker("Language", selection: Binding(
                    get: { profile.languages },
                    set: { value in library.setLanguages(value) }
                ).nativeSelectionFeedback()) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.name).tag(language.hints)
                    }
                    if !TranscriptionLanguage.allCases.contains(where: { $0.hints == profile.languages }) {
                        Text(profile.languages.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }.joined(separator: ", "))
                            .tag(profile.languages)
                    }
                }
                .drillDownPickerStyle()
                .disabled(library.isSavingSettings)
            } else {
                Picker("Language", selection: $settings.language.nativeSelectionFeedback()) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.name).tag(language)
                    }
                }
                .drillDownPickerStyle()
            }
            if let library {
                @Bindable var library = library
                Toggle("Use WisprClone Library", isOn: $library.isEnabled)
                if library.isEnabled {
                    Text(library.status).foregroundStyle(.secondary)
                    if let resolution = library.modelResolution { Text(resolution).foregroundStyle(.secondary) }
                    if library.unassignedCaptureCount > 0 {
                        Button("Assign \(library.unassignedCaptureCount) Held Recordings to This iCloud Account") {
                            Task {
                                assignmentAccount = await library.accountForConfirmation()
                                confirmsAccountAssignment = assignmentAccount != nil
                            }
                        }
                        .confirmationDialog("Assign held recordings to this iCloud account?", isPresented: $confirmsAccountAssignment) {
                            if let assignmentAccount {
                                Button("Assign Recordings") { Task { await library.assignUnownedCaptures(account: assignmentAccount) } }
                            }
                        } message: {
                            Text("Their owner could not be confirmed when they were recorded. Assign them only if they belong to the current account.")
                        }
                    }
                    Button("Retry Uploads") { Task { await library.publish() } }
                    Button("Free Uploaded Local Audio") {
                        Task {
                            localReleaseAccount = await library.accountForConfirmation()
                            confirmsLocalRelease = localReleaseAccount != nil
                        }
                    }
                        .confirmationDialog("Remove uploaded audio from this device?", isPresented: $confirmsLocalRelease) {
                            if let localReleaseAccount {
                                Button("Free Uploaded Local Audio") {
                                    Task { await library.freeUploadedLocalAudio(account: localReleaseAccount) }
                                }
                            }
                        } message: {
                            Text("Only RemoteCoder originals acknowledged by iCloud are removed. Unpublished audio stays here. iCloud sync does not confirm an independent backup.")
                        }
                }
            }
        } header: {
            Text("Dictation")
        } footer: {
            if library?.isEnabled == true {
                Text("Shared settings and archived recordings use your private iCloud library.")
            }
        }
    }

    private var selectedModel: TranscriptionModel {
        library?.model(fallback: settings.model) ?? settings.model
    }

    private var modelSelection: Binding<TranscriptionModel> {
        Binding(get: { selectedModel }, set: { value in
            if let library, library.isEnabled { library.setModel(value) }
            else { settings.model = value }
        })
    }

    private var providerSelection: Binding<TranscriptionProvider> {
        Binding(get: { selectedModel.provider }, set: { value in
            guard value != selectedModel.provider, let model = value.models.first else { return }
            modelSelection.wrappedValue = model
        })
    }

    private func captureDescription(_ capture: TranscriptionCapture) -> String {
        switch capture {
        case .streaming: "Transcribes while you speak"
        case .batch: "Transcribes after you stop"
        }
    }
}
