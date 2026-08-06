# Privacy

BvfAudio collects nothing.

There is no analytics, no telemetry, no crash reporting, no advertising identifier, no usage measurement, no remote logging. No data leaves your device for our benefit, because there is no benefit for us to derive. There is no "us" in the operating sense; there is no server, no account system, and no backend.

## Your keys and passphrase

BvfAudio uses standard public-key encryption. Three things matter:

- **Public key**: encrypts new recordings. Safe to share or sync; that's the whole point.
- **Private key**: decrypts recordings. Encrypted with your passphrase (locked).
- **Passphrase**: decrypts (unlocks) the private key for playback.

The keys live on macOS. The public key gets synced to iCloud Drive if you enable it, but the private key never leaves. The passphrase ideally exists only in your head.

## Local-only operation

BvfAudio never makes a network call. It only reads and writes files on the local device, whether capturing or consuming. If you opt in, cross-device sync (recording on iOS, or using iCloud Write-Only mode on macOS) encrypts audio files to a local folder which iCloud Drive syncs between devices. iCloud is doing the transport, not BvfAudio. Your passphrase never leaves your device, and the unlocked private key exists only in memory. Neither the maintainers of BvfAudio nor Apple can hear your recordings.

Playback decrypts and decodes recordings entirely in memory; no plaintext audio file is written to disk. Transcription also runs entirely on-device through Apple's Speech framework: the decoded audio is handed to the on-device recognizer from memory and never leaves the device. (It is handed to that Apple recognizer to do the work — so this is on-device confinement, not a claim that no component ever receives the audio.)

For the cryptographic details, see [BvfKit's SECURITY.md](https://github.com/openbvf/BvfKit/blob/main/SECURITY.md) and the [bvf file format spec](https://github.com/openbvf/bvf/blob/main/SPEC.md).

## What the app reads on your device

Apple requires that apps disclose use of certain system APIs even when no data is transmitted off-device. BvfAudio uses:

- **Microphone**: while the record screen is open. The mic is warmed the moment you open the screen so the first sample lands the instant you tap record; backing out releases it.
- **Speech recognition** (macOS only): when you ask to transcribe a recording. Recognition runs on-device.
- **User defaults** (`UserDefaults`): to remember your preferences and a per-device identifier used to name unsaved drafts so multiple devices don't overwrite each other's work-in-progress.
- **File timestamps**: to detect changes to key files and to group saved recordings by date in the browser.

Every read stays on-device. Nothing is reported anywhere.

## What we don't have

- No account.
- No password reset, because there is no password we hold.
- No "your data" page, because there is no data on our side.
- No way to recover a forgotten passphrase. If you forget it, your recordings are unrecoverable. This is intentional.

## Third parties

The only third party is Apple, and only if you opt into iCloud Drive sync. Apple's own privacy policy covers iCloud storage. BvfAudio contacts no other service.

## Changes

This policy is versioned alongside the source at the [BvfAudio repository](https://github.com/openbvf/bvfaudio). Material changes are noted in release notes.

## Contact

Security disclosures and privacy questions: see [BvfAudio's SECURITY.md](https://github.com/openbvf/bvfaudio/blob/main/SECURITY.md) for the contact channel. Do not file public issues for security or privacy concerns.
