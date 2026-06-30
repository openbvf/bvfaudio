import SwiftUI
import BvfAppKitDecrypt
import UniformTypeIdentifiers
import AVFoundation

struct AudioView: View {
    @Environment(FileAccessManager.self) var fileAccessManager
    @Environment(AppSettings.self) var appSettings
    @Environment(SyncManager.self) var syncManager
    @Environment(iCloudManager.self) var cloudManager
    @State private var viewModel: AudioViewModel?

    @State private var showTagSheet = false

    nonisolated func isAudioFile(_ url: URL) -> Bool {
        guard let uttype = UTType(filenameExtension: url.pathExtension) else { return false }
        let supportedTypes = AVURLAsset.audiovisualTypes()
        return supportedTypes.contains { $0.rawValue == uttype.identifier } && uttype.conforms(to: .audio)
    }

    var body: some View {
        Group {
            if let viewModel = viewModel {
                VStack {
                    DateRangeRowView(
                        startDate: Binding(get: { viewModel.startDate }, set: { viewModel.startDate = $0 }),
                        endDate: Binding(get: { viewModel.endDate }, set: { viewModel.endDate = $0 }),
                        selectedPreset: Binding(get: { viewModel.selectedPreset }, set: { viewModel.selectedPreset = $0 }),
                        isReady: viewModel.folderURL != nil && viewModel.publicKeyURL != nil,
                        isLoading: viewModel.isLoading || viewModel.isDecrypting,
                        responseMessage: viewModel.responseMessage,
                        setupErrorMessage: nil,
                        onDecrypt: {
                            await viewModel.loadEntries()
                        }
                    )

                    List {
                        ForEach(viewModel.groupedDates, id: \.day) { day, dates in
                            Section {
                                ForEach(dates, id: \.self) { date in
                                    AudioRowView(
                                        date: date,
                                        isPlaying: viewModel.currentlyPlayingDate == date && viewModel.isPlaying,
                                        onTap: { viewModel.play(date: date) },
                                        onTranscribe: {
                                            let dates = viewModel.selectedDates.contains(date)
                                                ? Array(viewModel.selectedDates)
                                                : [date]
                                            viewModel.startTranscription(dates: dates)
                                        },
                                        viewModel: viewModel
                                    )
                                    .selectableItem(date: date, isSelected: viewModel.selectedDates.contains(date)) {
                                        viewModel.handleSelection(date, in: viewModel.filteredDates)
                                    }
                                }
                            } header: {
                                Text(day.dayWithWeekdayString)
                            }
                        }
                    }

                    if viewModel.currentlyPlayingDate != nil {
                        Divider()
                        AudioTransportView(
                            isPlaying: viewModel.isPlaying,
                            currentTime: viewModel.currentTime,
                            duration: viewModel.duration,
                            onTogglePlayPause: { viewModel.pause() },
                            onSeek: { viewModel.seek(to: $0) },
                            onSeekRelative: { delta in
                                let target = max(0, min(viewModel.duration, viewModel.currentTime + delta))
                                viewModel.seek(to: target)
                            }
                        )
                    }
                }
                .browseToolbar(
                    viewModel: viewModel,
                    configuration: BrowseToolbarConfiguration(
                        clearHelpText: "Clear all audio",
                        importFileFilter: isAudioFile
                    ),
                    showTagSheet: $showTagSheet
                )
                .padding()
                .browseModals(
                    viewModel: viewModel,
                    showTagSheet: $showTagSheet
                )
                .toolbar {
                    ToolbarItem {
                        if viewModel.isTranscribing {
                            Button(action: { viewModel.cancelTranscription() }) {
                                Label("Cancel Transcription", systemImage: "xmark.circle.fill")
                            }
                            .help("Cancel transcription")
                        } else {
                            Button(action: {
                                viewModel.startTranscription(dates: Array(viewModel.selectedDates))
                            }) {
                                Label("Transcribe to Bedit", systemImage: "text.bubble")
                            }
                            .disabled(viewModel.selectedDates.isEmpty)
                            .help("Transcribe to Bedit")
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task {
            if viewModel == nil {
                viewModel = AudioViewModel(fileAccessManager: fileAccessManager, appSettings: appSettings, syncManager: syncManager, cloudManager: cloudManager)
            }
        }
    }
}
