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
- Groq API key (hardcoded in MurmurKit/TranscriptionService.swift)
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
