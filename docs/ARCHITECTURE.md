# Architecture

`TalkieCore` is a Foundation-only data/policy/export library. `Talkie` is the SwiftUI executable. One observable main-actor `AppStore` coordinates services and UI; capture, inference, insertion, and persistence do not share a generic plugin backend.

| Responsibility | Implementation |
| --- | --- |
| Desktop UI | SwiftUI window, settings, commands, MenuBarExtra; semantic system colors and native controls |
| Shortcut/overlay | Carbon hotkeys, narrow nonactivating AppKit NSPanel |
| Microphone-only capture | AVAudioEngine input tap; bounded copied buffers, serial writer queue |
| Online capture | ScreenCaptureKit audio + microphone outputs only; no screen output |
| Durable audio | Separate-source 15-second WAV chunks, explicit conversion to mono 16 kHz, file synchronization and atomic metadata |
| ASR | Pinned Argmax OSS WhisperKit, multilingual Large v3 Turbo, transcription task, local tokenizer override, dictionary token hints |
| Text inference | Actor-isolated, loopback-only Ollama client with pinned runtime/digests, JSON schemas and bounded requests |
| Insertion | Accessibility target snapshot, focus/selection observation and immediate revalidation; direct selected-text replacement |
| Persistence/export | App-owned JSON session files, immutable finalized raw versions, linked corrections and summaries, deterministic complete exports |

Source timestamps use host-clock presentation times converted to offsets from the recording's host-clock origin. Microphone-only AVAudioTime host times use the same clock. The start instant is also stored in UTC, together with the user's time-zone identifier. Pauses occupy positions on the recording timeline rather than collapsing later timestamps. Wall-time interpretation is recording start UTC + offset; interruptions and missing/unknown tails remain marked. Source labels distinguish capture sources, not speakers. An accelerated conversion fixture measured approximately 7 ms difference between last source end times; this is not a live-call synchronization guarantee.

Audio callbacks do no model inference. Microphone callbacks copy into at most 16 queued buffers and stop on overflow. ScreenCaptureKit audio callbacks arrive on the serial writer queue. Chunk conversion/writes and metadata persistence occur there. Expensive WhisperKit and Ollama work uses actors; post-recording transcription is intentionally serial. Saved drafts allow recovery of already recognized chunks after interruption. Successful raw versions are snapshots; reprocessing or correction appends a version.

Digital silence below -80 dBFS is conservatively marked detected silence and skips recognition. A non-silent chunk that yields no text is marked processed with an explicit note that speech may have been missed. Coverage completeness only means known intervals were accounted for, not perfect transcription. Failed/pending/missing intervals prevent a completeness claim. Exports include every available segment and coverage marker regardless of summarization state.

Cleanup OFF bypasses the editor service. Cleanup ON retains raw ASR and produces a reviewable candidate; it never automatically inserts cleaned output. Critical-token checks assist review but cannot verify semantic equivalence. Summary output references segment IDs; ID validation prevents invented links but does not prove the claim. Bounded pairwise merges reject missing evidence references and input/output budget failures. A failed summary never replaces or removes transcript data.

Automatic insertion uses no clipboard and no synthetic Return/Send. It requires supported AX text roles and settable selected text, refuses secure/terminal/ambiguous command inputs, and checks unchanged app, element, UTF-16 selection, and whole field value immediately before writing. Post-write verification detects uncertain consumption; no automatic retry follows. Unsupported change notifications cause fallback. Explicit Copy is user initiated and intentionally changes the pasteboard.

Normal inference has two data routes: local model/audio files and `127.0.0.1:11434`. Speech setup explicitly downloads pinned Hugging Face artifacts; app downloads enforce HTTPS, expected host, size and available hashes. The WhisperKit subclass bypasses its download/tokenizer fallback. Text requests have an ephemeral URLSession, empty proxy configuration and rejected redirects. Ollama is launched with cloud disabled and loopback binding. Dependency resolution and setup scripts contact official public sources. No analytics, transcript upload, messages, or automatic external AI submission are implemented.

The personal bundle reuses an existing Apple Development identity when one is available, with an ad hoc fallback. Its stable development designated requirement allows trust to survive code changes; ad hoc signing's code hash can require new grants. It has no App Sandbox or fabricated assistive entitlements. macOS TCC manages Microphone, Accessibility, and Screen & System Audio Recording. `script/build_and_run.sh` gracefully requests existing talkie processes to terminate and save before replacing the stable bundle. Explicit self-tests disable the regular global shortcut and schedule exit outside their async task. There is no publication/notarization infrastructure.
