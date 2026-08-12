import SwiftUI
import BvfAppKitDecrypt

struct AudioRowView: View {
    let date: Date
    let isPlaying: Bool
    let onTap: () -> Void
    let onTranscribe: () -> Void
    var viewModel: AudioViewModel

    @State private var showTagPopover = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            let tags = viewModel.metadata.tags(for: date)
            if !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                .lineLimit(1)
            }

            Spacer()

            Text(date.timeString)
                .font(.caption)
                .foregroundStyle(.secondary)

            if isPlaying {
                Image(systemName: "waveform")
                    .foregroundColor(.accentColor)
                    .symbolEffect(.variableColor.iterative)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Manage Tags") {
                showTagPopover = true
            }
            .disabled(!viewModel.metadataLoaded)
            if #available(macOS 26.0, *) {
                Button("Transcribe to Bedit") {
                    onTranscribe()
                }
                .disabled(viewModel.isTranscribing)
            }
            Button("Delete") {
                viewModel.showDeleteConfirmation = true
            }
            Button("Change Date...") {
                viewModel.datePickerValue = date
                viewModel.showDatePicker = true
            }
            Button("Export") {
                Task {
                    await viewModel.exportSelected()
                }
            }
            .disabled(viewModel.selectedDates.isEmpty)
        }
        .tagPopover(
            isPresented: $showTagPopover,
            date: date,
            selectedDates: viewModel.selectedDates,
            viewModel: viewModel
        )
    }
}
