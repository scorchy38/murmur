# Murmur native dictation

This implements the **Mac** experience in [the supplied specification](voice-spec.md).
The shared `Voice` module contains the native service adapter and portable transcript,
credential, language, audio and ownership contracts. The existing iOS/watchOS/keyboard
clients still use their legacy recorder/upload service; this update does not claim to
redesign those clients. CI isolates their credential injection after Mac packaging.

## Native interpretation

The spec's final paragraph places the service adapter inside native apps. Mac microphone
frames therefore go directly to the upstream WebSocket through `NativeVoiceStream`.
There is no localhost server, first-party product token, product account, organization
policy endpoint, Node addon, SoX subprocess or extra WebSocket hop. A user-owned API key
in Keychain admits a native session. Provider identity, setup fields and error mapping
remain inside the adapter; dictation surfaces expose product states, never model names.

The application is a native menu extra, not a terminal or conversation coordinator.
The Shift modifier has dependable native down/up events, so release ends capture directly.
A 160 ms warmup and 400 ms admission protect ordinary Shift typing; another key or modifier
cancels warmup. Native tap admission requires an empty accessible text field and debounces
rapid modifier taps. Menu-bar recording is an explicit alternative to a global gesture.

Live text belongs to the overlay, rather than repeatedly mutating foreign application
editors. On activation we snapshot the original accessible field, text, UTF-16 selection,
and application identity. Final insertion requires all of them still to match. Only the
selected span is written, with boundary spaces and cursor placement. Unsupported editors,
changed drafts, moved focus and recovered provisional text retain a reviewable result and
clipboard fallback. Generic application text fields have no owned submit function: **Murmur
never presses Return, sends a prompt, invokes a tool, or grants permission from speech**.
There is consequently no native auto-submit or double-tap-send action.

## Specification coverage

| Spec sections | Mac implementation |
| --- | --- |
| 1–3 | Separate capture, normalized stream, controller, presentation, commitment; observable state; generation invalidation; nested enablement wins |
| 4–5 | AVAudioEngine capture and AVAudioConverter; active microphone probe before enabling; native device/permission explanations |
| 6 | Exact 20-language allowlist, English fallback hint, English/native aliases; printable ASCII vocabulary, 50 terms / 1,024 characters |
| 7–9 | Guarded Shift hold/tap; Escape and Ctrl+C consumed for cancellation; processing blocks starts; tap 15-second inactivity and 120-second cap |
| 10–11 | Capture before connection; ordered pre-ready queue; mono little-endian 16-bit 16 kHz PCM; specified RMS level function; latest 16 levels |
| 12–13 | Native authenticated TLS WebSocket; setup acknowledgement before audio; internal product event boundary; WebSocket pings instead of forwarding product KeepAlive JSON to the supplier |
| 14–15 | Replacement hypotheses; corrected text before endpoint; finalized segments; idempotent input close; 1.5-second no-data and five-second hard drain bounds; interim salvage |
| 16–17 | One 250 ms early retry; one evidence-gated whole-audio replay; partial salvage marked for review; rolling 3 failures / 10 seconds breaker; bounded error categories |
| 18–20 | Anchored final insertion with exact draft/focus/selection equality; overlay preview isolation; no submission without a submit owner |
| 21–22 | Native Liquid Glass on macOS 26, material fallback on 14–15; adaptive centered live text, long-text scroll, audio meter, warmup, processing, result review; reduced-motion behavior |
| 23–24 | Cancellation/disposal/sleep/display change teardown; no late resurrection; memory-only Mac recordings; separate attempt summaries; counts rather than transcript telemetry |
| 25–29 | Private selected transcription adapter; SMART + disabled automatic activity detection; activityStart/activityEnd controls; authoritative final replacement; resource caps; usage metadata when supplied |
| 30–32 | State/gesture/controller/contract acceptance tests plus real-window development fixtures; live supplier/device acceptance remains required |

A standalone global Mac utility has no active terminal project/branch context. It supplies
coding vocabulary plus explicit user terms; it does not scan project files, infer projects
from unrelated working directories, or transmit editor contents as recognition hints.
Terminal-specific footer budgets, command parsing, syntax decoration and character-repeat
stripping are not copied into native controls.

## Resource and lifetime limits

- One local capture owner; an active or processing recording blocks replacement.
- Setup deadline: 12 seconds. Ephemeral URLSession uses system TLS/proxy handling.
- Pre-ready audio: 2 MiB. Supplier message: at most 1 MiB of PCM, aligned to 16-bit samples.
- Audio history and outbound audio queue: at most 480 seconds × 32,000 bytes/second each.
- Hold recording cap: 480 seconds, below the upstream ten-minute session limit. Tap: 120 seconds.
- Backpressure exhaustion is an explicit limit failure; no middle chunks are silently dropped.
- Buffered/replay audio is released on success, failure, cancellation and disposal. Mac capture
  does not create a temporary recording file.
- Keepalive is a transport ping every eight seconds after setup, and is cancelled on teardown.
- Each actual connection has an independent local attempt UUID, queued byte count, optional
  reported token count and outcome. Usage totals sum available per-attempt receipts. Queued
  bytes are evidence of offered audio, not a fabricated provider acceptance or billing receipt.
- Release stops the microphone immediately; queued audio precedes the one activityEnd control.
  Already-accepted capture callbacks and the resampler tail drain in order before activityEnd. Later buffers are ignored. Final text is drained before closing transport.
- Errors preserve text for review; cancellation discards the active recording and never completes it.

## Setup and acceptance

Open **Settings → Connection**, save a Gemini API key, and enable dictation. Enabling performs
an actual microphone-open probe and a speech setup check before persisting enabled intent.
The separate connection test also opens a session without sending microphone audio. Enable
Accessibility under **Settings → Dictation** for Shift gestures and safe external insertion.
A new ad-hoc build can require renewed macOS privacy grants.

The automated checks use fake capture/stream boundaries and require no credentials or audio.
They verify release-before-ready ordering, correction/endpoint ordering, ownership generations,
superseded error attempts, cancellation, no duplicate completion, silent-input classification,
replay gating, rolling-window recovery, Shift typing, and cancellation-key consumption.

```sh
swift test --package-path MurmurKit
xcodegen generate
xcodebuild test -scheme Murmur -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY='-' DEVELOPMENT_TEAM=''
```

Real-window fixtures use synthetic text and never start capture or network services:

```sh
python3 scripts/render-voice-previews.py /path/to/Debug/Murmur.app
```

The render helper captures only its preview window. The invoking terminal needs Screen
Recording permission. Fixture entry points are excluded from Release builds.

Before release acceptance, use an entered key to verify actual supplier authentication,
quota failures, proxy/TLS setup, microphone changes and revocation, upstream final corrections
and drain latency, native insertion in supported editors, multiple monitors/Spaces/fullscreen
apps, Keychain access across signed updates, and cancellation usage receipts. An automated
mock run or a successful compilation does not establish any of those live conditions.

Provider contract checked against:
- https://ai.google.dev/gemini-api/docs/live-api/live-transcribe
- https://ai.google.dev/api/live
- https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe

## Local validation record

The universal Mac 2.0.0 preview archive built successfully for Apple Silicon and Intel.
The local suite passed **27 tests**: 13 portable contract tests and 14 native capture,
controller and gesture tests. The native audio fixture checks actual 48 kHz stereo to
16 kHz mono conversion, including the resampler tail; lifecycle fixtures verify tail
ordering before stream finalization and cancellation on event-tap loss.

Nine real-window synthetic previews were rendered: listening, processing, editable
result, long text, warmup, error, Library, Connection setup and menu extra. Offscreen
NSView bitmap capture does not reliably include composited SwiftUI text/glass, so these
artifacts use window-only macOS screenshots from a development fixture process.

The packaged app passes strict code-signature verification. Its resources exclude local
Secrets.plist files, its binary has no known embedded credential markers, and Release
excludes the development fixture entry point. YAML parsing and diff whitespace checks
pass. The installed CI app was not replaced. Supplier/device end-to-end acceptance has
not been performed with a user-entered Gemini key; the preview must complete that check
before being described as production validated.

## Enable-dictation crash repair (2.0.3)

The 2.0.2 crash was symbolicated to the WebSocket ping callback resuming a checked
continuation twice after setup-check cancellation. Ping completion now takes the
continuation under a lock before resuming it; cancellation settles any pending
ping, and subsequent pong/error callbacks are ignored. Short connection checks do
not start a recurring keepalive. Recording sessions retain their keepalive with
the same protected cancellation path.

Regression tests cover success followed by cancellation/error, cancellation
followed by success, and simultaneous callbacks (100 iterations of eight callbacks).
All 16 shared and 19 native tests pass. The installed 2.0.3 build completed the
actual Enable Dictation flow using the saved credential: the local microphone probe
and speech setup succeeded, enabled intent persisted, and the process stayed alive.
This is setup-path validation, not a claim that speech transcription itself was tested.

Startup and periodic permission refresh also now use a non-interactive Keychain
metadata lookup rather than reading the secret. Secret reads occur on explicit
connection or recording actions, so background checks cannot raise an unlock prompt.

## Global shortcut admission

Microphone permission and a working speech credential enable menu-bar recording;
receiving Shift outside the app additionally requires macOS Accessibility access.
The menu reports “Shortcut setup” until `CGEvent.tapCreate` actually succeeds, and
provides an explicit Accessibility action instead of claiming that Shift is ready.
The application refreshes that grant every three seconds and reconnects the event
tap after approval. macOS requires the user to grant Accessibility; the app does
not alter the privacy database. Ad-hoc app replacements may require toggling the
existing Murmur entry off and on to refresh its identity.

## Shadow Mode and interaction polish (2.1)

Settings → Dictation includes optional **Shadow Mode**. It suppresses all center-screen
panels, including warmup, processing and result review. Completed nonempty text still
passes through the existing automatic clipboard copy, then skips external insertion
and closes any overlay. Recording/processing state stays visible in the menu bar;
Escape and Ctrl+C still cancel without an overlay. Errors remain available in the
menu. The setting defaults off, and is disabled during an active recording so a
session cannot change its delivery mode midway through.

Hold activation now defaults to two seconds, with 1.5-, 2-, 2.5- and 3-second choices.
Warmup appears only during the final 700 milliseconds. Another key cancels admission,
so Shift-plus-punctuation within the ordinary typing interval does not start capture
or flash a hint. The hint has a single-line intrinsic size, and its hosting panel
keeps the screen's bounds rather than shrinking to the hint's fitting size.

History UI calls recordings **prompts**. The menu preview is a non-selectable,
three-line, clipped excerpt; Copy still copies the complete prompt. The Library
opens at 1080 × 720 with a 900 × 580 minimum content size, a bounded 240–320-point
sidebar and at least 520 points for the editor. It selects the latest prompt on
opening, offers a visible search field, and keeps long text inside a scrolling
editor. Real-window fixtures cover long menu text, the minimum-size Library with
a long selected prompt, and the warmup hint.

Launch at login defaults on for new/unconfigured preferences. The installed release
registers the main application through SMAppService; smoke tests and development
fixtures do not. An explicit off choice is saved and respected. Settings reports
required macOS approval or registration failure instead of treating a requested
preference as proof of successful registration.


### Local usage accounting (2.1 build 7)

Settings → Usage tracks completed-text word counts, captured dictation duration (including pauses), completed prompts, a seven-day word chart, current streak, longest prompt, and estimated typing time saved at 40 WPM minus recording time. Today, seven-day and all-tracked filters apply to totals; the activity chart always shows the past seven days.

The local versioned ledger lives in Application Support/Murmur/Usage/usage-v1.json, independently of the 50-item prompt history. It retains no transcript/audio, writes atomically with private permissions, replaces cumulative per-connection receipts instead of summing snapshots, and preserves cancelled/retried/replayed connection usage. Active entries become interrupted after restart. Corrupt/unknown-version ledgers are preserved and the UI reports a storage error. Previews, smoke launches and tests never open the real ledger.

Gemini 3.5 Transcribe Live list rates verified against https://ai.google.dev/gemini-api/docs/pricing on 2026-11-08: USD 3.50/M audio input tokens and USD 21/M text output tokens including separately reported thoughts. Rate snapshots are persisted per recording; monetary aggregation uses Decimal. Reported token counts take precedence. When receipts are absent, estimate audio at 25 tokens/second from bytes queued per connection and final text at roughly 4 characters/token. Older tracked prompts fall back to roughly 1⅓ tokens per word. Estimates never become supplier receipts; partial reported counts replace only their corresponding estimates. Queued audio may exceed delivered audio after a failed connection. These are explicitly labeled approximations, and unavailable unfinalized output remains unknown. Setup checks, other apps/devices, taxes, credits and free-tier billing are outside this local estimate. Old recordings cannot reliably be backfilled. The Google AI Studio usage link is the account-level source of truth.

Build 8 diagnostic: a short synthetic TTS prompt returned authoritative inputTranscription and generationComplete but no usageMetadata during an additional 18-second drain. Thus ordinary successful sessions can lack receipts for this model; the UI now surfaces heuristic estimates immediately rather than an empty cost panel. Timing displays minutes and seconds and exposes the 40-WPM typing baseline. Delayed receipts from a superseded connection attach to its originating attempt, never the newer attempt. No diagnostic speech was captured from the user; no transcript or key was logged.
