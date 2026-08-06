# Security

BvfAudio is a thin SwiftUI shell on [BvfAppKit](https://github.com/openbvf/BvfAppKit). This file covers only what's specific to recording-and-playing-audio.

## Reporting vulnerabilities

If you find a security issue, **do not open a public issue.** Instead:

- **GitHub Security Advisories** (preferred): [Submit a private advisory](https://github.com/openbvf/bvfaudio/security/advisories/new)
- **Email**: bvf@newvoll.net

## Out of scope

- App-lifecycle surface: [BvfAppKit/SECURITY.md](https://github.com/openbvf/BvfAppKit/blob/main/SECURITY.md).
- Encryption, key derivation, libsodium interop: [BvfKit/SECURITY.md](https://github.com/openbvf/BvfKit/blob/main/SECURITY.md).
- The `.bvf` file format and its threat model: [bvf/SECURITY.md](https://github.com/openbvf/bvf/blob/main/SECURITY.md).

## In scope

### Plaintext audio in memory during recording

Audio frames pass through memory between the mic and the encryption stream; they have to, since AAC encoding happens before the bytes hit the encrypted file. The window is per-buffer (a fraction of a second of PCM at a time), the buffer is released as soon as the AAC frame is written, and nothing is persisted in cleartext on disk along the way. The on-disk part of that claim was verified on 2026-06-29 by capturing all file-write events during a record→encrypt session via Apple's Endpoint Security framework: no audio-extension scratch files appeared anywhere under the recording user's account. A memory attack on the running, unlocked process could observe these buffers; the mitigation is the same as for any decrypted content held in a running app: keep the device under your control while recording, and lock the app when you walk away.

### Plaintext audio in memory during playback

Playing a recording decrypts it into memory and decodes it to PCM there; no plaintext audio file is written to disk. Decryption yields only an in-memory buffer, which Core Audio decodes through an in-memory read callback — the decoder is never handed a file path or a whole encoded blob it could spool, and the decoded PCM is fed to `AVAudioEngine`, which receives raw samples only, never an encoded container. Nothing decodable lands in the app container. This replaced an earlier `AVAudioPlayer(data:)` path whose opaque handling of the encoded buffer could not structurally rule out a spooled copy. As with recording, the PCM exists only in the running, unlocked process; lock the app when you step away.

### Transcription handoff to Bedit

If you choose to transcribe a recording, the transcript is held in memory during recognition, then written as a `.bvf`-encrypted text file into your [Bedit](https://github.com/openbvf/bedit) folder (encrypted to the same public key the recording was encrypted to). The transcript is never placed on disk in plaintext. Recognition runs entirely on-device through Apple's Speech framework, but note the one residual: transcription decodes the recording to PCM and hands those samples to the recognizer, a closed on-device component. It receives the audio in memory (never a file), nothing is transmitted off the device, and any scratch the recognizer keeps lives in system space outside the app container — not in your backed-up data. The handoff requires Bedit to be configured against the same iCloud container; if it isn't, the transcribe action surfaces an error rather than writing anywhere unexpected.

### Mic-active indicator while the record screen is open

The mic is "warmed" the moment you open the record screen, before you tap record. This eliminates the cold-start delay on Bluetooth headsets (which negotiate SCO on first use) and ensures the first sample is captured the instant you start. Consequence: the system mic-in-use indicator (the orange dot on iOS, the lock-screen indicator on macOS) lights up while the record screen is visible even when you aren't actively recording. Backing out of the record screen tears the engine down and releases the mic.

### Audio import

BvfAudio can import external audio files, converting them to encrypted recordings. **The original source files are left in place.** BvfAudio does not delete, move, or sanitize them. If the source contains audio you don't want sitting on disk in plaintext, delete it yourself.

### Fake recordings via iCloud

If you've enabled iCloud sync and your iCloud account is compromised, an adversary can write `.bvf` files into your audio folder. BvfAudio will sync them down and present them as recordings. There is no per-file signature today that lets you distinguish your own writes from injected ones; the cryptographic guarantee is confidentiality of contents, not authenticity of authorship. Mitigation: protect your iCloud account.

### Public key substitution via iCloud

If you've enabled iCloud sync, BvfAudio publishes your public key to a shared iCloud location so iOS captures can encrypt to it. An adversary who can write to that location could swap your key with their own; subsequent iOS captures would encrypt to the adversary's key and be readable by them. BvfAppKit's `PubkeyDistributor` watches that location and surfaces a mismatch when the remote key diverges from the local one. See [BvfAppKit/SECURITY.md](https://github.com/openbvf/BvfAppKit/blob/main/SECURITY.md) for the mechanism.
