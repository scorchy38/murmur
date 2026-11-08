# Voice and dictation

## 1. Architecture and ownership

Dictation turns locally captured speech into ordinary composer text. Recording, transcription, preview rendering, text commitment and prompt submission are separate transitions. A recognized phrase is not an assistant answer, a tool invocation or an automatic permission grant.

```text
active terminal input
    -> guarded recording gesture
    -> local microphone capture
    -> PCM frames over authenticated first-party WebSocket
    -> speech-service adapter
    -> interim replacement / finalized segment events
    -> recording controller
    -> anchored composer preview
    -> committed editable draft
    -> optional normal prompt submission
```

The terminal owns microphone lifecycle, key handling, local buffering, input anchors and user-facing state. The first-party service owns authentication, upstream session admission, audio translation, provider event normalization and cost accounting. The conversation coordinator owns any prompt submitted after dictation.

Sections 2–24 specify the terminal and first-party wire contract. Sections 25–29 specify the service implementation using the selected transcription backend. The provider adapter is a deployment component; its model identity and credentials are private server configuration. The terminal presents dictation, listening, processing and recoverable errors without exposing the underlying provider/model selection.

This document complements [TERMINAL_COMPOSER.md](TERMINAL_COMPOSER.md), [TERMINAL_FRAME_ENGINE.md](TERMINAL_FRAME_ENGINE.md), [AUTHENTICATION_AND_CREDENTIALS.md](AUTHENTICATION_AND_CREDENTIALS.md), [MEDIA_ASSETS.md](MEDIA_ASSETS.md), and [USAGE_ACCOUNTING_AND_BILLING.md](USAGE_ACCOUNTING_AND_BILLING.md).

## 2. Settings and enablement

Effective user intent is `voice.enabled` when present, otherwise the top-level `voiceEnabled`; it must be exactly true. Nested false therefore overrides a true top-level value. The settings command writes both enablement fields together and preserves other nested voice settings.

The nested settings are:

| Setting | Behavior |
|---|---|
| `enabled` | Explicit dictation intent |
| `mode` | `hold` or `tap`; default `hold` |
| `autoSubmit` | Submit completed hold-mode dictation when eligible; defaults off |
| General language setting | Selects dictation-language hint through normalization |
| Reduced-motion preference | Removes recording/processing animations |

User intent alone is insufficient. Runtime availability also requires eligible account authentication and organization policy allowing voice. The UI recomputes auth-dependent availability when authentication state changes. The stream connection refreshes credentials before reading the access token.

The command is an interactive local action, hidden when account/policy availability fails; it is not an SDK/headless recording command. Its availability check precedes mode parsing and the off branch.

The enable command accepts empty arguments, `hold`, `tap`, or `off`, case-insensitively after trimming. Empty input toggles off when already enabled; otherwise it enables the saved mode or hold default. Unknown modes report usage without changing settings. Explicit off also persists disabled state through the admitted settings writer.

Enablement checks policy/auth, recording availability, stream availability, dependencies and microphone permission before committing settings. Settings-write failure is an enablement failure, not a successful activation with unsaved preferences.

A background/hosted execution surface without local audio access cannot use this local capture path. A remote conversation does not imply that its server has access to the user's microphone.

## 3. UI state and host state

The voice provider supplies a reactive store:

```text
voiceState: idle | recording | processing
voiceError: optional capture/setup error
voiceInterimTranscript: current complete recording preview
voiceAudioLevels: recent normalized sample levels
voiceWarmingUp: gesture recognition is approaching capture activation
awaitingVoiceSubmitDoubleTap: completed hold input can use submission gesture
```

The provider also owns the audio-level smoother, reset whenever recording ends. Hooks outside the provider are an integration error rather than silently creating an unrelated store.

A controller instance owns recording generation, connection-attempt state, transcript accumulation, timers, pending audio, optional replay audio, signal evidence and callback ownership. Shared host state retains the lazily loaded recorder module and a recent-early-failure circuit breaker. Several mounted input surfaces must not be treated as independent permission to seize the same microphone: gesture admission identifies the active input owner.

State changes are observable snapshots. Avoid emitting duplicate state changes when the value is unchanged. Disposal invalidates asynchronous ownership, cancels timers, stops capture, closes the stream and clears retained recording data.

## 4. Recording backends

Prefer the packaged native audio addon through its Node-API wrapper. Load it lazily and memoize availability. Try the packaged module first, then supported packaged filesystem locations. Match native package architecture/platform to the application distribution; a successful loader probe is not proof that a microphone has been authorized.

The recording API supplies audio buffers and an end callback, plus start/stop/is-recording operations. If a prior native recording is active, stop it before starting a replacement. Starting native capture can fail and fall through to the external recorder.

The fallback uses SoX's `rec` executable with an argument array, not a shell command string:

```text
rec -q --buffer 1024 -t raw -r 16000 -e signed -b 16 -c 1 -
```

Capture stdout is audio. Stderr is drained. The helper uses piped streams, hidden console windows where applicable and the application's helper process resource class. Process close/error informs the recording controller. Stop requests SIGTERM for an owned fallback recorder.

The recorder wrapper can support a silence effect, but the active hold/tap controller starts it with silence detection disabled. Hold-release inference, tap timers and the transcription service's utterance decisions govern this workflow. Do not add the recorder's optional silence effect on top and assume it preserves the same lifecycle.

Fallback spawn returns a started indication before every asynchronous process/device error can be known. An executable-presence check is not a complete microphone-open test; capture failure can still arrive after the UI began recording.

## 5. Dependency and microphone checks

Executable probes use `--version`, a three-second wait and no project cwd dependence. Native availability satisfies dependency discovery. Otherwise require the recording command suite and provide platform-appropriate installation guidance. A package-manager installation command is guidance for the user, not automatically executed by enabling voice.

Under a Linux-on-Windows subsystem, recording may require a graphical subsystem's audio bridge and SoX's PulseAudio backend. Without such audio support, guide the user to a native host session rather than pretending microphone capture is available in the isolated environment.

Native microphone permission checking performs a short start/stop recording probe. The authorization-status accessor exposed by a native wrapper is not a substitute for this active probe in the enable path. If native capture is unavailable, the external recorder's access/error behavior determines usability.

A denied microphone result gives platform privacy-settings guidance. A remote/no-device environment, missing executable and device access failure have different explanations. Do not report all of them as a speech-recognition network failure.

## 6. Language normalization and vocabulary

The terminal normalizes the configured language by lowercasing/trimming, accepting a recognized short code, resolving supported language-name aliases, or taking a recognized base subtag. Empty input defaults to English. Unsupported values fall back to English with an explicit enablement hint.

The terminal's supported short-code set is:

```text
en es fr ja de pt it ko hi id ru pl tr nl uk el cs da sv no
```

Language-name aliases include English and native-language names for these entries. Enabling voice can show the resolved language hint twice per selected language; switching language resets that hint budget. An unsupported-language fallback is explained rather than silently counted as ordinary successful language selection.

The recognition vocabulary starts with coding terms: MCP, symlink, grep, regex, localhost, codebase, TypeScript, JSON, OAuth, webhook, gRPC, dotfiles, subagent and worktree. Add a usable project-directory basename and tokens from the current branch. Split camel-case and path/separator-delimited branch terms, retaining terms longer than two and at most twenty characters. A project basename can be up to fifty characters.

The active hook obtains this vocabulary without a file-list argument. It does not scan every source file or transmit file contents to build recognition hints. Deduplicate and limit the outgoing vocabulary to fifty terms.

Before putting vocabulary into the header, replace commas with spaces, remove nonprintable/non-ASCII characters, collapse whitespace, trim and deduplicate again. The comma-separated header is limited to 1,024 characters; stop before exceeding it. This sanitized ASCII limit is distinct from language support and does not mean non-ASCII speech is unsupported.

Vocabulary hints can reveal project/branch terminology to the speech service. Apply the same account, privacy and service admission decisions as the audio stream rather than treating hints as nonuser data.

## 7. Gesture registration and input ownership

Dictation uses the Chat-context push-to-talk action, defaulting to Space. Resolve the effective single-chord binding from the active keymap. A later conflicting binding can invalidate an earlier voice chord. Multi-chord sequences are not interpreted as this recording gesture.

Distinguish a plain unmodified character from a noncharacter/modifier chord. A plain character participates in ordinary text entry until the hold detector recognizes intentional repetition. A custom chord can be consumed immediately.

The main input mount intercepts voice keys before ordinary input handling. A modal input owner disables this gesture. Transcript view and noninsert editor modes can stop a plain character from being treated as typed voice activation. A surface-level key blocker also prevents activation where another interaction owns it.

Escape or ordinary Ctrl+C while voice is recording/processing is consumed by voice cancellation first, preventing the same key from also triggering an unrelated input action. Plain activation characters remain ordinary typing when dictation is unavailable, the binding is invalid or the relevant input owner is inactive.

The gate controls gestures; it is not an operating-system global microphone hotkey.

## 8. Hold-to-talk mechanics

Terminal input often provides key repeats rather than a dependable key-up event. Hold mode infers release from a short gap between repeated activation keys.

For a plain character:

1. Count repeated key units, including a terminal event containing several identical characters.
2. Preserve ordinary initial typing rather than consuming the first space.
3. At two repeated units, mark voice warmup and show “keep holding…”.
4. At five units, consume activation, establish a composer anchor and start recording.
5. Remove only the gesture's trailing activation characters, respecting the preserved pre-gesture floor.
6. While recording, refresh a 200 ms release timer as repeats arrive.
7. When repeats stop, finish recording and enter processing.

A 120 ms gap resets an incomplete plain-character gesture and clears warmup. A nonmatching key also resets that gesture. Fullwidth spaces are normalized for matching/removal while unrelated composer characters remain intact.

For a custom noncharacter chord, capture can start immediately and the initial repeat fallback is 2,000 ms. The controller's ordinary fallback is 600 ms. Once repetition is observed, both use the 200 ms release-gap timer. This accommodates initial keyboard-repeat delays without assuming continuous key-down notifications.

When network readiness flushes pending audio, it cancels the prior release timer and refreshes it when repeats have already been observed. Network readiness and key-repeat timing therefore have separate effects on the finish deadline.

The controller does not start another recording while processing. If module loading or admission leaves it idle after activation, restore the anchor instead of leaving stripped/spacer text as if recording succeeded.

## 9. Tap-to-talk mechanics

Tap mode starts only from an empty eligible composer. The next intentional tap finishes recording. A nonempty ordinary prompt must remain editable; its spaces do not unexpectedly start a tap recording.

Debounce repeated key units within 120 ms so a held key or batched terminal input does not start and immediately stop capture. Strip gesture characters without retaining them in the dictation result.

Refresh the tap inactivity timer on received interim/final transcript events. After fifteen seconds without such progress, finish. Independently cap a tap recording at 120 seconds. These are client recording timers; neither is the upstream provider's maximum session lifetime.

Processing blocks another tap recording. Tap-mode submission remains subject to the completed-text, word-count and live submit-owner checks below; “tap to send” is not permission to send an empty or obsolete draft.

## 10. Starting a recording

Starting checks that the recorder module was loaded and that the host circuit breaker admits a new attempt. Then:

```text
state = recording
capture recording start time
clear accumulated transcript, audio history and signal flags
reset retry/replay and connection evidence
increment recording generation
check recording availability asynchronously
start capture with silence detection disabled
buffer audio while establishing authenticated transcription connection
resolve language and vocabulary
connect stream
on ready, flush buffered audio in order
```

Availability and capture callbacks compare their recording generation against the current generation. A cancelled or replaced start must not resurrect recording, retain a newly opened stream or overwrite another draft.

A superseded capture start is ignored. A genuine capture-start failure records a bounded early failure, displays its available device-specific hint and returns idle after cleanup. A recorder close before receiving any audio is additional early-failure evidence.

The controller starts capture before awaiting network readiness. It therefore does not discard the first words while authentication/connection is pending.

## 11. Audio buffering and level measurement

Wire audio is mono signed 16-bit PCM at 16,000 samples/second: 32,000 bytes per second. Audio remains audio bytes; it is not converted into a conversation text block before transcription.

Maintain an ordered connection-pending buffer. When ready, coalesce chunks toward 32,000-byte frames and send them in order, then forward new capture buffers directly. Coalescing combines chunks; it does not split a single oversize native chunk automatically.

For ordinary hold/tap recording, also retain audio for the narrowly admitted silent-drop replay. This recording-local buffer is cleared after completion/cancellation. It is not a durable audio attachment, a transcript store or a background upload queue. The basic capture layer does not add an independent byte cap to this retained recording history; service resource limits are specified separately below.

Compute audio level from little-endian signed samples using root-mean-square amplitude:

```text
rms = sqrt(sum(sample_i^2) / sample_count)
normalized = sqrt(min(rms / 2000, 1))
```

Empty audio yields zero; an incomplete final byte is not a complete sample. Keep the latest sixteen normalized levels. A value above 0.01 establishes that some audio signal occurred for later failure classification. This evidence is not a speech detector or a reliable transcript endpoint.

## 12. First-party streaming request

Connect to the authenticated service's `/api/ws/speech_to_text/voice_stream` endpoint, converting the configured HTTPS origin to secure WebSocket transport.

The request query carries:

```text
encoding=linear16
sample_rate=16000
channels=1
endpointing_ms=300
utterance_end_ms=1000
language=<normalized code>
use_conversation_engine=true
optional forward_interims=typed
```

The typed-interim option is default off behind a feature setting and can be explicitly enabled by environment configuration. Both interim event forms are understood by the client.

Headers carry the refreshed account bearer token, client identity/platform and optional sanitized vocabulary. Never expose the provider credential to the terminal. The connection uses configured proxy/TLS handling and the common WebSocket environment adapter.

A missing account access token returns no stream; the controller reports sign-in/credential availability and clears recording state. Command enablement and per-recording credential refresh are separate checks.

The stream helper returns a handle before the socket is necessarily ready. Audio is sent only from the ready callback. A successful handle allocation is not a connection receipt. This layer does not configure a separate explicit connection-establishment deadline in the stream options; recording, finalization and service-side admission limits remain distinct timers.

## 13. Application messages

Audio frames carry raw bytes. Application control/result frames are JSON:

| Direction | Frame | Meaning |
|---|---|---|
| Client to service | `KeepAlive` | Maintain idle stream liveness |
| Client to service | `CloseStream` | No more audio; finalize pending transcription |
| Service to client | `TranscriptInterim` with `data` | Replace current utterance hypothesis |
| Service to client | `TranscriptText` with `data` | Also replace current utterance hypothesis |
| Service to client | `TranscriptEndpoint` | Commit latest hypothesis and clear it |
| Service to client | `TranscriptError` | Typed transcription error |
| Service to client | `error` | General service error |

Send one keepalive when the socket opens and then every eight seconds while open. Keepalive does not supply synthetic audio and does not create a prompt turn. Clear that interval when closing/disconnecting.

Malformed JSON is ignored. Unknown event types are ignored. Known text frames must carry text strings; parsing here is not a complete structural schema check for every arbitrary payload, so the service must enforce the emitted event contract. Both text event types carry replacement hypotheses, not append-only tokens. For example:

```text
Interim("change teh")
Text("change the")
Endpoint
```

commits “change the” once. Appending both event bodies would duplicate and preserve incorrect text.

An endpoint with no current text commits nothing. The terminal assembles finalized segments with one separating space for this recording; the backend must not emit already committed prefixes as a new utterance.

## 14. Recording transcript assembly

For each interim event, trim the current utterance and combine it with previously finalized recording segments for preview. Final segment events append to the recording's finalized accumulator. They also update preview, but the ordinary hold/tap composer receives its completed transcript only when recording finishes or a recovery path deliberately salvages it.

Consequently, “finalized by recognition” and “committed into the editable composer” are different boundaries. The live dimmed recording span can include several finalized recognition segments plus one provisional utterance.

Any accepted transcript event clears the host's recent early-failure history. Transcript callbacks check recording generation. Error callbacks additionally check the current connection-attempt counter. These are separate guards; do not describe all transport callbacks as sharing one universal attempt ID.

The active composer uses hold/tap recording. It does not enable an ambient focus-triggered always-listening mode. Microphone capture starts from the admitted gesture and ends through the lifecycle described here.

## 15. Finalization and late text

Finishing stops capture immediately and transitions to processing. Keep the network connection alive long enough to drain the transcription result.

The stream's finalize operation:

1. Marks finalize requested; repeated finalize calls do not create another drain operation.
2. Arms a 1,500 ms no-data deadline and a 5,000 ms safety deadline.
3. On the next event-loop turn, forbids more audio and sends `CloseStream` when open.
4. Cancels the no-data deadline when a subsequent text result arrives after closing input.
5. Resolves when an endpoint arrives after closing input, the socket closes, or a deadline fires.
6. Before resolving, promotes a remaining interim to a final segment so recognized speech is not silently lost.

The zero-delay control send preserves ordering with already scheduled audio work. New chunks after input close are dropped. Closing input and closing the socket are different operations; shutting the socket immediately can discard final corrections.

Already closed/closing sockets resolve through the closed path. On stream errors or socket closure, promote an unreported interim once before reporting the error. A promoted interim is salvage, not proof the provider delivered an authoritative final transcript.

After drain, trim the accumulated recording text, close the stream, clear replay audio and inject nonempty text through the guarded composer callback. Clear preview and return idle. A finalize exception is recorded and returns idle only if the current generation still owns that completion.

## 16. Retry, replay and partial salvage

### Early connection retry

While recording, a nonfatal stream failure before any transcript can retry once after 250 ms. Increment connection-attempt state so superseded error callbacks cannot repeatedly restart the flow. Keep the still-unsent pending capture buffer available for the new ready callback. Fatal failures, including HTTP client-error upgrade refusals, do not use this retry.

This retry is not a guarantee that every chunk sent on a broken connection is automatically replayed. The separate silent-drop recovery has tighter evidence requirements.

### Silent-drop replay

After finalization reports no data, retry the captured audio once only when audio signal was detected, a WebSocket had connected, no transcript was delivered/accumulated, and retained audio exists. Close the old stream, wait 250 ms, create a fresh stream, flush the retained audio in coalesced frames and finalize it.

Collect finalized replay text, then pass it through the same completed-composer callback. A replay can cause another upstream recognition attempt and cost; account for it rather than recording one supplier call per user gesture by assumption.

### Midstream failure

On a terminal stream error, preserve nonempty accumulated finalized text before cleanup. The stream helper can also promote the pending interim before the controller sees the error. Salvage follows the same insertion callback as ordinary completion, including the applicable auto-submit rules. Do not label salvaged text as an independently verified final recognition result.

Show a recoverable stream-error notification, clear unsent audio, invalidate the recording generation, close resources and return idle. A cancelled recording is different: it discards without invoking the completed-text callback.

## 17. Failure classification and circuit breaker

For an empty result after more than two seconds, distinguish:

| Evidence | User-facing classification |
|---|---|
| No meaningful local audio signal | Microphone/input device or permission problem |
| Audio occurred, but stream never connected | Connection/authentication/network failure |
| Audio occurred and stream connected | No recognized speech |

Short accidental activations do not generate the same empty-result warning. Store normalized connection-failure evidence where available. A diagnostic reachability probe can query the service's hello route with a 1,500 ms timeout, no redirects and privacy gates; it does not send another recording.

HTTP upgrade status 101 is not treated as a refusal. Other upgrade refusals drain the HTTP response and destroy the rejected request. Status 4xx is fatal for the early retry path. Preserve bounded status/security-mitigation categories, rather than logging arbitrary response bodies as event labels.

Unexpected socket close codes other than ordinary 1000/1005 can report an error when not already finalizing. Distinguish preconnection closure from a stream that had opened. An explicit expected finalization suppresses redundant late stream errors while still collecting text.

The host breaker suppresses new starts after three recent early failures within ten seconds. It prunes expired failure timestamps on a new start. Log/display the breaker transition once until the history changes; retain an expected device-specific hint when available. Any successful transcript clears the early-failure history. The rolling window can also make starts eligible again without requiring a successful request while paused.

Errors appear as immediate warning notifications, normally for ten seconds. Capture setup can also retain `voiceError` for state/status. Text divergence, no insertion anchor and unavailable submit owner are insertion outcomes, not microphone failures.

## 18. Composer anchoring and replacement

At activation, capture the exact text before the cursor, suffix after the cursor and expected whole draft value. Gesture stripping can establish this anchor before recording begins. If recording becomes active without a gesture-created anchor, the active composer captures one from its current cursor.

For preview `P`, anchored prefix `L` and suffix `R`:

```text
left_space = " " if L is nonempty, does not end in whitespace, and P is nonempty
right_space = " " if R is nonempty and does not begin with whitespace
value = L + left_space + P + right_space + R
cursor = length(L + left_space + P)
```

Before applying, require the current draft to equal the last expected value written by the voice flow. If the user, paste handler or another input source changed it, stop overwriting that draft. The final insertion checks the same equality and reports a divergence outcome instead of appending at an obsolete cursor.

This is replacement of the voice-owned span. It preserves suffix text, inserts boundary spacing, and moves the cursor to the end of the preview rather than to the end of the entire draft. Do not repeatedly append each interim event.

Final insertion uses the completed recording text, includes boundary spacing only when there is actual text, updates the expected draft and advances the anchor prefix to include that committed text. A missing anchor causes the insertion to be skipped with a diagnostic outcome.

Cancellation restores original prefix/suffix only when the current draft still matches the voice-owned expected value. If it diverged, leave the user's edits intact. Idle state clears the anchor. These ownership checks protect text; the visual interim-range calculation is separate and must not itself be treated as mutation authorization.

## 19. Streaming text appearance

Publish the voice span's start/end offsets through the composer's `interimRange`. Main-input painting adds a dim style at low decoration priority. Existing higher-priority syntax, path or selection layers retain their ordinary precedence. Agent-view inputs pass that range through their text input's dim-range property.

During recording, the current complete recording preview appears at the cursor and can be revised in place. On completion, the finalized draft uses ordinary text styling after the interim range clears. This is not a separate growing assistant transcript row for each partial phrase.

Changing preview text updates the composer value/cursor through the normal store, preserving wrapping, layout and terminal repaint ownership. Resize and scrolling remain frame-engine concerns; the voice code does not write raw recognized text directly to stdout.

Disable ordinary prompt-ghost suggestion eligibility while a voice interim span is active so suggestion text does not compete with provisional speech. External editing/divergence can leave a provisional range calculation awaiting lifecycle cleanup; an offset alone must never justify replacing manually edited content.

The transcript does not store every interim as a user message. Only eventual normal submission becomes conversation input through the coordinator. An unsent completed dictation remains an editable draft.

## 20. Submission rules

After successful final insertion, attempt automatic submission only when:

- The surface has a live submit function.
- Mode is tap, or hold-mode `autoSubmit` is enabled.
- The completed recording has at least three recognized word-like units.

The word-count helper combines token/word segmentation evidence, including the runtime's Unicode word segmenter, so this is not a raw three-character threshold. A shorter result remains editable. The submit function returns whether a live submission owner accepted the request; method existence alone is insufficient.

Main composer submission emits through registered submission listeners. When none exists, it returns false. Voice completion does not construct an independent model request beside that owner.

For eligible completed hold input that was not submitted, arm a double-tap submission affordance when the surface supports submission. It requires the plain activation character at the end of the draft and two taps within 300 ms. Defer acceptance by 120 ms to distinguish further repetition. Remove the gesture's trailing character, then submit only if voice remains idle and that affordance is still armed.

A different key, cursor away from the end, a new recording or a superseding gesture clears the affordance. The delayed action reads the current draft when it fires; it does not retain a frozen copy of the originally recognized text. The explicit double-tap path does not reapply the three-word auto-submit threshold; that threshold belongs to automatic completion submission. Tap mode does not use this hold-mode double-tap path.

Some agent-view query/reply adapters deliberately provide text setters without a submit function. There, dictation edits the local query/reply and normal explicit view actions decide whether to filter, dispatch, attach or reply.

## 21. Indicators, footer precedence and reduced motion

Recording presentation distinguishes hold “listening…” from tap recording with a record indicator and “tap to send”. Processing shows “Voice: processing…” or the compact status-row equivalent. Warmup says “keep holding…”. Idle has no recording indicator.

The active compact status row prioritizes exit confirmation, then paste activity, then voice state, before ordinary timed hints, paste expansion, selection-copy guidance, parked permissions and shell status. A voice status therefore does not override an active exit confirmation or paste transaction.

The ordinary footer can offer “hold <binding> to speak” when voice is enabled, idle, the binding exists and layout/interaction conditions permit it. Warmup takes precedence over that educational hint. The persistent seen budget is three appearances, counted once per host/UI lifetime when actually shown. Dense and regular footer layouts arbitrate this hint differently; do not force it into every narrow row or display it while another surface owns input.

The recording cursor is audio-reactive. It uses the newest level, scales by 1.8, clamps, and smooths with previous-value weight 0.7. Choose a block-height character from the available block sequence with a minimum nonblank height. Below level 0.15, use a neutral gray; otherwise cycle through an animated hue, with terminal-specific color adjustments. Animation updates at 50 ms intervals. Processing uses a separate two-second color cycle.

Reduced motion disables the animated recording cursor and the processing pulse; the static recording/processing text remains. Reset the level smoother when recording stops so a new session does not inherit a previous loud sample.

## 22. The view

The UI would look something like this: as soon as the shortcut is invoked which would be hold shift instead of ctrl + space now, a transparent overlay will cover the mac screen and the live transcription will be shown in center of the screen, handled properly for different length and size scenarios. The whole UI/UX of the app should be deleted and rewritten using native MacOS latest liquid glass native things rather than handrolled stuff. There is no limit to imagination, UX and creativity in this, spend a lot of time and thinking here.

## 23. Cancellation and teardown

Cancellation invalidates the recording generation, cancels hold/fallback/tap timers, stops the native/fallback recorder, closes the stream, clears audio/transcript histories, removes meter samples and returns idle. It does not call the completion callback.

Disabling voice while mounted runs cleanup. Component disposal runs cleanup once and ignores future input updates. A late ready callback closes its stream when its recording no longer owns the session; late transcript callbacks are ignored after generation invalidation.

Stopping capture, closing input, closing transport, clearing preview and restoring anchored text are separate actions. A normal finish preserves/drains text; a user cancellation discards it and performs guarded anchor restoration. Do not reuse one generic “stop” routine that accidentally submits after Escape.

Loading the audio module is lazy and cached at host scope. If the first gesture precedes load completion, show a retryable not-ready outcome rather than trying to call an undefined recorder. Module load completion itself is not authority to start a recording after the user cancelled.

## 24. Data, observability and accounting

The client records enable/disable, gate results, capture start/failure, connection/retry, recording duration, transcript character count, audio-signal evidence, replay, cancellation, insertion success/divergence and finalization outcome. Count actual speech-service attempts separately from user gestures and submitted agent turns.

Keep raw audio out of product-event payloads. The normal recording/replay buffer is memory-owned and cleared by its lifecycle. Do not persist recordings just to reconstruct a text draft. Transcript strings in operational errors/logs require the ordinary redaction/content policy; identifiers, byte counts, durations and bounded failure categories are preferred for telemetry.

A speech request can cost money even when the user cancels, recognized text is empty, the composer diverged or no agent prompt was submitted. Record audio duration/bytes, supplier session/attempt identity and available provider usage receipts. Replay and failed attempts remain separate supplier costs under one recording owner. Main-agent token usage begins only if a prompt is actually submitted and executed.

## 25. Selected speech-service backend

Use `gemini-3.5-transcribe-live` behind the first-party API. Its published contract supports live transcription over WebSockets, text output, mono 16 kHz PCM, separate interim/final transcription fields, language hints and vocabulary biasing. [Live transcription guide](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe).

Live sessions have a ten-minute limit; live word-level timestamps and speaker diarization are unavailable. Vocabulary accepts up to 1,000 terms, with smaller targeted lists preferred. The terminal's fifty-term budget fits that contract. [Model capabilities](https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe).

Choose Smart transcription with manual utterance boundaries for this deployment. Google recommends disabling automatic activity detection and sending explicit activity-start/end signals for Smart mode so natural pauses do not prematurely split corrections or formatting. [Smart-mode endpointing guidance](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-5-transcribe).

This choice is private backend configuration, not an assertion that a terminal can call the provider using its product bearer token. Keep product authentication and supplier authentication separate. Configure the deployment's supported service region/credentials and model through the server's normal secret/configuration system.

The provider connection must complete setup before forwarding queued audio. Its session configuration is established at connection setup. Realtime audio and activity controls have different message fields; with manual activity detection, end the utterance using the activity-end signal rather than the automatic-detection audio-stream-end signal. Provider input transcriptions and other completion messages are not guaranteed to arrive in a single ordering. [Live API reference](https://ai.google.dev/api/live).

## 26. First-party service adapter

The following service contract preserves the terminal behavior above while translating to the selected backend:

```text
authenticate product WebSocket request
check organization voice policy and account admission
validate advertised PCM format, language and vocabulary
reserve recording/attempt resources and cost owner
connect upstream transcription session
configure private model, text output and recognition options
wait for upstream setup acknowledgement
open one manual utterance for the recording
forward admitted audio in order
translate upstream hypothesis/final events into terminal events
on CloseStream:
    flush pending audio
    end manual utterance once
    drain authoritative final text within service/client deadlines
    emit final replacement text before its endpoint
    release/close upstream resources
settle actual usage and recording outcome
```

The product endpoint's query fields are a compatibility contract, not provider query-string parameters. Translate format/language/vocabulary into the supplier session configuration. Treat endpointing hints according to the service's selected boundary policy. Do not pretend a 300 ms compatibility hint means automatic VAD remains enabled in the selected manual-boundary configuration.

The terminal already uses native PCM matching the selected upstream format, so the adapter can avoid unnecessary resampling. Validate frame alignment, sample format and channel count. A transport chunk boundary is not an utterance boundary. Aggregate/reframe for the upstream transport without reordering samples or discarding the start of speech.

Keepalive belongs to the product connection. Do not forward its JSON as audio, start a new speech turn for it or assume it is the supplier protocol's keepalive message. Likewise, `CloseStream` means finish recognition, not immediately destroy both sockets.

Use a dedicated per-recording session unless a separately designed multiplexing protocol supplies independent recording IDs and ordering. Sharing one unsegmented supplier conversation among concurrent users or terminal fields would corrupt both transcript ownership and accounting.

## 27. Transcript normalization and final correction

The adapter must maintain a current uncommitted utterance hypothesis and an emitted-final boundary. Normalize provider event shapes before the terminal sees them.

For a provisional update, construct the latest full hypothesis for the current utterance and emit a replacement text event. Do not forward token deltas as if they were snapshots. If a transport/SDK emits incremental fragments, assemble those fragments into the adapter's snapshot first.

For an authoritative final result:

1. Resolve it to the current utterance/attempt.
2. Replace the provisional hypothesis with the authoritative text, including corrections.
3. Emit that text as a replacement snapshot.
4. Emit exactly one endpoint for that finalized segment.
5. Clear current hypothesis and record the emitted boundary.

A final text that differs from the latest interim must reach the terminal before the endpoint. For example:

```text
upstream interim: "rename cash manager"
upstream final:   "rename CacheManager"
product output:  Text("rename CacheManager"), Endpoint
```

The terminal then commits the corrected text. Emitting only an endpoint would instead commit the wrong preview. Sending the whole recording prefix again after an earlier endpoint would duplicate speech, because the terminal appends finalized segments.

The provider's interim and final fields are explicitly distinct. [Interim/final contract](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe). The service's own boundary bookkeeping must remain stable across duplicate callbacks, a late transport close and a client finalize request; a socket-close callback is not a second final segment.

Normalize errors into bounded product categories and useful user-facing messages. Never echo supplier credentials, internal model identifiers or raw request headers. A provider error may leave a usable preview; preserve the client salvage contract while recording that final authority was unavailable. Do not manufacture a provider-final receipt for salvaged text.

## 28. Service deadlines, resource limits and recovery

Choose service deadlines that fit the client's drain behavior: it begins a 1.5-second no-data wait and a five-second safety wait after release. Promptly forward upstream text progress so the no-data wait is not mistaken for a silent drop. An actual endpoint is sent only for the appropriate final boundary. If the supplier cannot finish in time, preserve error/salvage semantics instead of returning an empty successful endpoint and losing text.

The first-party service must bound connection admission, upstream setup, queued pre-setup audio, per-frame size, total recording duration, concurrent recordings and final-drain time. Put these values in server configuration, measure them against real recorder chunk sizes and surface limit exhaustion explicitly. The terminal's coalescer does not split every individual native buffer; an arbitrarily tiny service frame cap would reject valid capture.

Tap's 120-second client cap fits within the published upstream session duration. Hold has no equivalent two-minute cap in this controller. Enforce an explicit product recording limit within the supplier limit, or design a fully ordered rollover protocol. Do not roll a stream silently and concatenate overlapping audio/transcripts: that needs committed-segment identities, a replay window and deduplication ownership.

On terminal disconnect/cancel, stop accepting audio, close the upstream session, release reservation resources and settle incurred usage. An abandoned socket must not retain a billable upstream session indefinitely.

Keep the client's one early retry and one evidence-based silent-drop replay distinct from server retry. The server must not add unlimited transparent whole-recording replays. Assign each actual supplier connection/attempt an internal identity and retain the parent recording owner for reconciliation. With the current wire contract, a reconnect cannot assume cross-connection exactly-once recognition; the service cannot infer which audio was accepted from a socket write alone.

Apply backpressure through bounded queues. If the upstream cannot keep up, refuse/terminate with a recoverable limit outcome rather than silently dropping middle PCM chunks and returning a seemingly complete transcript. Bound memory on both downstream and upstream legs, and release buffers after their replay/commit purpose ends.

## 29. Deployment policy and validation

Product policy selects Smart/manual transcription for prompt dictation. Expose a future verbatim option only as an explicit product behavior with its own tests; do not switch formatting mode mid-recording because an interim phrase resembles source code. Preserve paths, identifiers, negation and spoken corrections in acceptance fixtures.

Keep supplier setup, event field names and configuration casing inside one adapter. Test against the SDK/API version actually deployed. A general live conversational-agent setup is not a substitute for the selected transcription model's capability contract.

The terminal's language allowlist remains narrower than the supplier's language capabilities. Widening it is a product change requiring normalization, UI guidance and multilingual fixtures; do not silently pass an unsupported terminal setting that currently falls back to English.

Deployment acceptance must cover real microphone/device permission behavior on supported hosts, actual WebSocket/proxy/TLS handling, supplier authentication and quota errors, partial/final correction ordering, upstream drain latency, cancellation resource release and cost receipts. Isolated transport/composer tests do not establish real-device or supplier availability.

## 30. State transitions and failure matrix

| Trigger | State/action | Draft consequence |
|---|---|---|
| Warmup repetition below activation threshold | Warmup hint only | Ordinary initial typing retained |
| Admitted hold/tap start | Recording; capture and connect | Anchor established |
| Interim text | Recording preview replacement | Dimmed anchored span updated if still owned |
| Recognition endpoint during recording | Accumulate finalized segment | Complete recording preview remains editable only through its owner |
| Hold release gap / tap finish | Processing; stop capture and finalize | Await late correction |
| Completed nonempty text | Insert and consider submit | Normal draft or ordinary submitted prompt |
| Empty result after meaningful duration | Classify signal/connection/speech | Restore/clear preview through current lifecycle |
| Early nonfatal stream error | One delayed reconnect | Preserve pending capture ownership |
| Silent no-data result with evidence | One audio replay | Insert only recovered completed text |
| Midstream error | Salvage recognized text, notify, cleanup | Same insertion/submit checks apply |
| Escape/Ctrl+C cancel | Invalidate, stop, close, discard | Restore original anchored draft only if unchanged by user |
| Manual draft divergence | Skip later voice mutation | Preserve manual edits |
| Modal/nonediting input owns gesture | Do not activate from that key | Normal input owner handles it |
| View unmount or voice disable | Dispose/cleanup | No late recording resurrection |
| Supplier/session limit | Explicit service error and resource cleanup | Preserve salvageable input without claiming complete recognition |

## 31. End-to-end pseudocode

```text
on_voice_gesture(event):
    require active input owner, effective setting, auth and policy
    recognize hold repeats or tap transition
    capture prefix/suffix/expected draft
    start recording generation

on_audio(bytes):
    update bounded audio-level history
    remember audio-signal evidence
    retain recording-local replay data
    if product stream ready: send bytes
    else: queue bytes in order

on_product_text(snapshot):
    require current recording generation
    current_utterance = trim(snapshot)
    preview = finalized_recording_segments + current_utterance
    if draft == expected_voice_draft:
        replace anchored voice span
        publish dim range and cursor

on_product_endpoint():
    append nonempty current_utterance once to finalized segments
    clear current_utterance

on_finish():
    stop recorder
    state = processing
    finalize product stream and drain late text
    if tightly admitted silent drop: replay once
    if completed text and anchor still owned:
        commit editable text
        if eligible mode, word count and submit owner:
            request ordinary prompt submission
    clear recording resources and preview
    state = idle

on_cancel():
    invalidate generation
    stop recorder and close stream
    clear audio/text/timers
    restore anchored draft only if still voice-owned
    state = idle

service_recording():
    authenticate and admit product stream
    create selected upstream transcription attempt
    forward PCM and normalize provisional/final events
    finalize utterance once on product CloseStream
    emit corrected snapshot before endpoint
    close resources and settle actual supplier usage
```

## 32. Acceptance cases

- A short typed space remains a space; holding the configured character activates only after the required gesture.
- Terminal batched repeats do not start and instantly stop tap recording.
- Speech beginning before network readiness remains in order after connection.
- “change teh” followed by “change the” displays and commits only the corrected hypothesis.
- A provider final correcting an interim arrives before its endpoint.
- Several finalized utterances do not repeat earlier recording prefixes.
- Speech inserted in the middle of a draft preserves suffix text and cursor placement.
- A user edit during transcription prevents late final replacement.
- Escape cancels without invoking transcript completion or prompt submission.
- A returned preview during socket failure can be salvaged once without duplicate endpoints.
- Tap/auto-submit requires sufficient word-like text and an active submit listener.
- An agent-view text-only adapter never gains main-composer submission behavior accidentally.
- Audio signal, connection failure and no recognized speech show distinct outcomes.
- The breaker pauses repeated early failures and recovers after its actual rolling window.
- Reduced motion removes animation while preserving status information.
- Backend limit/cancellation paths terminate upstream work and settle any incurred cost.

For native apps, the server part is rolled into the app since there is no external server.