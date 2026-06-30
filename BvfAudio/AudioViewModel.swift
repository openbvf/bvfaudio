import Foundation
import Combine
import AVFoundation
import AppKit
import BvfAppKitDecrypt
import SwiftUI

@MainActor
@Observable
class AudioViewModel: BrowseViewModelBase {
    var currentlyPlayingDate: Date?
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var wasTruncated = false
    var isTranscribing = false
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var transcriptionTask: Task<Void, Never>?

    override var itemTypeName: String { "audio files" }

    @ObservationIgnored let cloudManager: iCloudManager

    init(fileAccessManager: FileAccessManager, appSettings: AppSettings, syncManager: SyncManager, cloudManager: iCloudManager) {
        self.cloudManager = cloudManager
        let range = DateRangePreset.last7Days.dateRange()
        super.init(startDate: range.start, endDate: range.end, appSettings: appSettings, fileAccessManager: fileAccessManager, syncManager: syncManager)
    }

    override func populate(from files: [URL]) {
        super.populate(from: files)
    }

    override func clearSensitiveData(reason: String? = nil) {
        loadTask?.cancel()
        loadTask = nil
        transcriptionTask?.cancel()
        stop()
        super.clearSensitiveData(reason: reason)
    }

    func play(date: Date) {
        if currentlyPlayingDate == date {
            pause()
            return
        }

        guard let session = session,
              let url = filesByDate[date] else { return }

        loadTask?.cancel()
        stop()

        isLoading = true

        loadTask = Task {
            defer { isLoading = false }

            do {
                let result = try await session.decrypt(contentsOf: url)

                guard !Task.isCancelled else { return }

                audioPlayer = try AVAudioPlayer(data: result.data)
                audioPlayer?.delegate = self
                audioPlayer?.play()

                currentlyPlayingDate = date
                isPlaying = true
                duration = audioPlayer?.duration ?? 0
                wasTruncated = result.wasTruncated
                startProgressTimer()

                if result.wasTruncated {
                    responseMessage = ResponseMessage("Playing truncated recording (incomplete)", type: .info)
                }
            } catch {
                guard !Task.isCancelled else { return }
                responseMessage = ResponseMessage("Playback failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    func pause() {
        if isPlaying {
            audioPlayer?.pause()
            stopProgressTimer()
            isPlaying = false
        } else {
            if let player = audioPlayer, player.currentTime >= player.duration {
                player.currentTime = 0
                currentTime = 0
            }
            audioPlayer?.play()
            startProgressTimer()
            isPlaying = true
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        stopProgressTimer()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentlyPlayingDate = nil
        currentTime = 0
        duration = 0
        wasTruncated = false
    }

    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
    }

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard let player = self.audioPlayer else { return }
                self.currentTime = player.currentTime
                // Keep idle timer alive during hands-free playback.
                self.idleTimer.userDidInteract()
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    func startTranscription(dates: [Date]) {
        guard !isTranscribing, !dates.isEmpty else { return }
        transcriptionTask = Task { [weak self] in
            await self?.runTranscription(dates: dates)
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
    }

    private func runTranscription(dates: [Date]) async {
        isTranscribing = true
        defer {
            isTranscribing = false
            transcriptionTask = nil
        }

        let total = dates.count
        var succeeded = 0
        var failed = 0

        for (index, date) in dates.enumerated() {
            if Task.isCancelled { break }
            responseMessage = ResponseMessage("Transcribing \(index + 1) of \(total)...", type: .info)
            do {
                try await transcribeOne(date: date)
                succeeded += 1
            } catch {
                failed += 1
                responseMessage = ResponseMessage("Transcription failed: \(error.localizedDescription)", type: .error)
            }
        }

        if Task.isCancelled {
            responseMessage = ResponseMessage("Transcribed \(succeeded) of \(total), cancelled", type: .info)
        } else if failed > 0 {
            responseMessage = ResponseMessage("Transcribed \(succeeded) of \(total), \(failed) failed", type: .error)
        } else {
            responseMessage = ResponseMessage("Transcribed \(succeeded) recordings to Bedit", type: .success)
        }
    }

    private func transcribeOne(date: Date) async throws {
        guard let session = session,
              let audioURL = filesByDate[date],
              let beditFolderURL = cloudManager.siblingAppFolderURL(for: "Bedit"),
              let publicKeyURL = fileAccessManager.publicKeyURL else {
            throw NSError(
                domain: "io.bvf.baudio.transcription",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing configuration"]
            )
        }

        let audioData = try await session.decrypt(contentsOf: audioURL).data

        let transcriptionService = TranscriptionService()
        let transcribedText = try await transcriptionService.transcribe(audioData: audioData)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let dateString = formatter.string(from: date)
        let formattedText = "[Transcribed from BvfAudio recording \(dateString)]\n\n\(transcribedText)"

        let textData = formattedText.data(using: .utf8) ?? Data()
        let transcriptionStaging = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bvfaudio-transcription-staging")
        _ = try await BvfStore.write(
            data: textData,
            to: beditFolderURL,
            publicKeyURL: publicKeyURL,
            date: date,
            suffix: "txt",
            stagingURL: transcriptionStaging
        )

        addTag("transcribed", to: [date])
    }
}

extension AudioViewModel: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            stopProgressTimer()
            isPlaying = false
            currentTime = duration
            audioPlayer?.prepareToPlay()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            stopProgressTimer()
            stop()
            if let error = error {
                responseMessage = ResponseMessage("Playback error: \(error.localizedDescription)", type: .error)
            }
        }
    }
}
