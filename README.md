<img src="bvfaudio-macos.svg" alt="" width="128" align="right">

# BvfAudio

BvfAudio is a private app to record and play back audio on macOS. You can also record from iPhone or iPad. Audio is encrypted as it's captured and decrypted only inside the app where you play it back, so there's never a readable copy on disk for Spotlight, backups, other software, or people using your computer to find.

iOS is record-only by design. An iPhone or iPad can record new audio but can never play it back, because the private key isn't on iOS at all. If your phone is taken, nothing on it is playable.

*Screenshots are on the App Store listing (coming with release).*

## Features

- Record and play back encrypted audio on macOS.
- Optionally enable iCloud Drive to record from iPhone or iPad; only your Mac can play back.
- Records straight to an encrypted file. Plaintext audio never touches disk.
- On-device transcription (no cloud); transcribed text can be saved encrypted to your [Bedit](https://github.com/openbvf/bedit) journal if you have one.
- Browse by date and filter by tag.
- No lock-in. Everything's a file named by date, decryptable with [bvf-cli](https://github.com/openbvf/bvf/tree/main/bvf-cli); decrypted contents are standard AAC.
- Export selection.
- Idle auto-lock.

## Install

- **macOS**: App Store (in progress), or [build from source](BUILDING.md). Requires macOS 26 or later.
- **iOS**: App Store (in progress). Requires iOS 18 or later.

## First run

You generate keys and choose a passphrase during onboarding (or reuse existing ones from another bvf app). The passphrase is the only thing standing between someone who has your keys and your audio files. There is no recovery, no support desk, no "forgot password" link. Ideally it only exists in your head. Make it [secure](https://www.eff.org/dice).

During onboarding, you can also choose to enable iCloud Drive so recordings made on your iPhone or iPad land on your Mac. You can change this later in preferences, where you can also rerun the onboarding wizard at any time.

## What this protects, and what it doesn't

Files at rest are unreadable without your passphrase. Full stop.

For the full threat model and cryptographic details, see [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

**BvfAudio protects you from:**

- Anyone who steals your Mac, iPhone, or iPad
- Someone logged into your Mac as you; passphrase on launch, auto-lock on idle, and can be set to lock the moment focus leaves the app
- Anyone using your iPhone or iPad, which can't play your recordings in the first place
- Anyone who copies your encrypted recordings; they might see encrypted blobs, never the audio
- AI agents, indexers, and other software that read files on your Mac; same answer
- Apple, or anyone who breaches iCloud; same answer

**BvfAudio does not protect you from:**

- Someone in earshot while you play a recording, or who films your screen
- A keylogger or a tampered BvfAudio binary. If your Mac is compromised at runtime, all bets are off.
- A forgotten passphrase. There is no recovery, and the recordings are gone.
- A memory attack on your running, unlocked Mac (see [SECURITY.md](SECURITY.md) for the nuances).
- Fake recordings from someone using your device. Anyone logged into your Mac, iPhone, or iPad can add a recording.
- Yourself, via advanced settings. Moving the private key off your Mac (to iCloud, a shared folder, a backup service that holds its own decryption key) puts it within reach of whoever can read that location.

## Backing up

Your recordings are encrypted files; back them up like any other files. An encrypted Time Machine backup doesn't increase exposure meaningfully since the recordings are already encrypted, and Time Machine adds a second layer at rest. For remote backup, use a service that lets you supply an encryption key the provider can't access, so a breach of the service doesn't put your recordings within reach of someone with your passphrase.

## License

MIT. See [LICENSE](LICENSE).

## Reporting issues

Bugs and feature requests: file an issue at https://github.com/openbvf/bvfaudio/issues.

Security issues: see [SECURITY.md](SECURITY.md). Do not file public issues for security.
