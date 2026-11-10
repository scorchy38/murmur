# Murmur

Native dictation for Mac: hold Shift, speak, and watch your words take shape in a centered live preview. Release to finish; Murmur inserts into an unchanged original text field or keeps your result ready to review and copy. The repository also includes the existing iPhone, Apple Watch, and keyboard clients.

## Features

- **macOS**: Guarded hold-Shift or tap-Shift dictation, live Smart transcription, native Liquid Glass on macOS 26, editable result review, searchable history, Keychain credentials, safe text insertion, cancellation and streaming recovery.
- **Setup and recovery**: Guided practice, alternate shortcuts, optional compact Shadow Mode feedback, guarded insertion/clipboard undo, and redacted diagnostics export. See [the reliability release and validation checklist](docs/reliability-release.md).
- **Personal vocabulary**: Saved names and technical spellings guide Gemini’s recognition using the audio and context. Murmur does not replace homophones after recognition. Stable name corrections in Murmur’s own editors can become vocabulary hints; this can be disabled in Personalize. Edits elsewhere are not automatically learned.
- **Editor compatibility**: Native Accessibility insertion where supported, with a guarded paste path for web and terminal editors. The original app and field must remain focused; text is also kept on the clipboard.
- **iOS**: Standalone app with record button and transcription history. Includes a custom keyboard extension for system-wide voice input.
- **watchOS**: Record from your wrist with a simple tap. View transcription history on a separate screen.
- **Cross-device sync**: All devices discover each other via Bonjour and exchange transcriptions in real time over the local network. No cloud account required.

## How It Works

On Mac, microphone audio streams as mono 16 kHz PCM to the native speech adapter using Gemini Smart transcription and manual utterance boundaries. Interim text is replaced in place; late final corrections arrive before commitment. Audio remains in memory and is cleared by the recording lifecycle. Completed text can be saved locally and optionally synced over a trusted local network. Dictation never automatically submits a message.

The existing mobile clients retain the legacy Groq upload path. See [native architecture, specification mapping, and validation](docs/voice-implementation.md) and [the supplied specification](docs/voice-spec.md).

## Project Structure

```
Murmur/
  Murmur/              macOS menu bar app
  MurmurMobile/
    iOS/               iPhone app
    watchOS/           Apple Watch app
    Keyboard/          iOS keyboard extension
  MurmurKit/           Shared Swift package (transcription, audio, sync, storage)
```

## Requirements

- Xcode 26+ (for native Liquid Glass APIs)
- macOS 14+, iOS 18+, watchOS 11+
- Mac: Gemini API key, saved in Settings → Connection to this Mac’s Keychain. Mac releases contain no embedded API keys.
- Legacy mobile: Groq API key via `Secrets.plist` or the mobile CI secret
- A trusted local network if you opt into transcription sync

## Building

Uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) for project generation.

```
# macOS
xcodegen generate
xcodebuild -scheme Murmur -destination 'platform=macOS' build

# iOS + watchOS
cd MurmurMobile && xcodegen generate
xcodebuild -scheme Murmur -destination 'platform=iOS Simulator' build
xcodebuild -scheme MurmurWatch -destination 'platform=watchOS Simulator' build
```

## Installation

Download the latest build from [Releases](../../releases).

### Mac

1. Open **Murmur-Mac.dmg**
2. Drag **Murmur** onto **Applications**, then eject the Murmur disk
3. Open Murmur from Applications (first launch: right-click → **Open** if macOS asks)
4. Open Murmur’s menu bar → **Set up Murmur** → **Get started**, then connect your Gemini API key and enable dictation
5. Allow Microphone access; grant Accessibility in **Settings → Dictation** for the Shift gesture and text insertion
6. Try the guided practice, then hold **Shift** alone for a moment, speak, and release to finish. Alternate shortcuts are available in Dictation settings. Press **Escape** to cancel
7. Review or copy the result if your original field changed or does not support safe insertion

The Mac minimum remains macOS 14, with native Liquid Glass on macOS 26 and a material fallback on earlier supported versions. A different ad-hoc build can require macOS privacy permissions to be granted again.

Mac builds check GitHub releases automatically and verify signed updates before installation. Manage this under **Settings → Updates**, or use **Check for Updates…** in the menu bar. Installing the new updater-enabled version is a one-time manual step. See [Mac distribution and release setup](docs/mac-distribution.md).

### iPhone

Since this isn't on the App Store, you'll use **AltStore** to install it.

#### One-time setup

1. On your Mac, go to [altstore.io](https://altstore.io) and download **AltServer**
2. Move AltServer to Applications, open it — it appears in your menu bar
3. Plug your iPhone into your Mac with a cable
4. Click the AltServer menu bar icon → **Install AltStore** → pick your iPhone
5. Sign in with your Apple ID when prompted
6. AltStore now appears on your iPhone

#### Install Murmur

1. AirDrop **Murmur.ipa** to your iPhone (or transfer via Files)
2. Open the file — it offers to open in AltStore
   (or: open AltStore → My Apps → tap **+** → select the IPA)
3. Murmur appears on your home screen
4. On first launch: **Settings → Privacy → Microphone** → allow Murmur

#### Keyboard Extension

1. **Settings → General → Keyboard → Keyboards → Add New Keyboard**
2. Select **Murmur**
3. Tap Murmur → enable **Allow Full Access** (needed for microphone)
4. Switch to the Murmur keyboard in any app to dictate

> **Note:** Free Apple IDs require apps to be refreshed every **7 days**.
> Keep AltServer running on your Mac + same Wi-Fi as your phone — it auto-refreshes.
> If the app stops opening, just open AltStore → **Refresh All**.
