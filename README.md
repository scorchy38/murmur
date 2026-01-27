# Murmur

Voice-to-text transcription app for Apple platforms. Record speech on any device and get instant transcriptions synced across Mac, iPhone, and Apple Watch over the local network.

## Features

- **macOS**: Menu bar app with global hotkey (Ctrl+Space) for push-to-talk dictation. Transcriptions auto-copy to clipboard and paste at cursor.
- **iOS**: Standalone app with record button and transcription history. Includes a custom keyboard extension for system-wide voice input.
- **watchOS**: Record from your wrist with a simple tap. View transcription history on a separate screen.
- **Cross-device sync**: All devices discover each other via Bonjour and exchange transcriptions in real time over the local network. No cloud account required.

## How It Works

Audio is recorded locally, sent to the Groq Whisper API for transcription, then the text is stored and broadcast to all connected Murmur devices on the same network. Each device acts as both a host and a client in a peer-to-peer mesh.

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

- Xcode 16+
- macOS 15+, iOS 18+, watchOS 11+
- Groq API key (set via macOS Settings → API, or `Secrets.plist`; CI injects from `GROQ_API_KEY` secret)
- All devices on the same local network for sync

## Building

Uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) for project generation.

```
# macOS
cd Murmur && xcodegen generate
xcodebuild -scheme Murmur -destination 'platform=macOS' build

# iOS + watchOS
cd MurmurMobile && xcodegen generate
xcodebuild -scheme Murmur -destination 'platform=iOS Simulator' build
xcodebuild -scheme MurmurWatch -destination 'platform=watchOS Simulator' build
```

## Installation

Download the latest build from [Releases](../../releases).

### Mac

1. Unzip **Murmur-Mac.zip**
2. Drag **Murmur.app** to your Applications folder
3. First launch: right-click the app → **Open** (bypasses Gatekeeper)
4. Murmur appears in your menu bar — hold **Control-Space** to dictate

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
