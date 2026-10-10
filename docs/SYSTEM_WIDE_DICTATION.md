# Automatic transient voice input — 2026-10-09

This replaces the earlier saved-dictation and blanket cleanup-preview contract. The existing WhisperKit engine, capture/writer, pinned local text service, and persistent meeting workflow are retained.

## Compact caret popup — 2026-10-10

The user reported successful live automatic insertion with Cleanup ON, accompanied by an unconfirmed-delivery recovery panel. The application/browser was not identified; this is user-reported ON delivery, not a completed native/browser OFF/ON matrix. No transcript from that report is retained here.

Normal recording/processing now uses a 238×44-point nonactivating indicator beside the captured caret (`AXBoundsForRange`), or outside the field bounds when caret geometry is unavailable. Placement flips above a low caret and clamps to the appropriate display's usable frame. Confirmed delivery closes the indicator immediately. The raw-cleanup fallback still gets a brief status. Failure/uncertainty gets a two-second compact message without transcript, Copy or Dismiss controls. The same one-result, 60-second recovery is available only when explicitly opened from the menu; opening it does not extend expiry.

The prior post-write verifier also required the focused AX node to remain identical. Editors can move/rebuild that node after accepting text, so this condition can falsely label a successful write uncertain. Verification now compares the entire **original captured field**, using AXValue and then full-range AXStringForRange/AXAttributedStringForRange if the value is stale. It never searches another field, trims surrounding text, infers delivery from an AX success code, or retries. Strict app/window/field/value/selection validation remains required **before** the single write. This addresses a concrete verification weakness; the exact cause in the user's unnamed editor cannot be independently reproduced yet.

All 22 Swift tests pass, including secondary/negative-coordinate displays, top-left AX conversion, bottom-edge flipping, stale-value full-field verification, surrounding-content rejection and invalidated operations. The signed bundle's owned disposable native fixture launches with selection intact; the computer-use screenshot captures its main window and omits the separate floating panel, so it is not visual proof of the popup's appearance or actual cross-app anchoring. `--overlay-preview` is an explicit synthetic UI diagnostic with no microphone, external text-field read or model call.

## Cause and implementation

The committed main snapshot sent every cleaned result to review, cleared the destination after cleanup, required writable AX selected text and working selection notifications, and saved dictation through the meeting repository. The local uncommitted cross-app work already introduced final target validation and a controlled Paste path; this change preserves it and separates voice input from the archive.

`DictationController` owns shortcut → capture → stop → ASR → optional cleanup → one delivery → idle. It snapshots settings and a UUID before showing a nonactivating panel. Cleanup OFF uses raw ASR without a text-model call. Cleanup ON inserts independently accepted cleanup automatically. Timeout (12 seconds), model failure, a review flag, or unexplained rewriting falls back to complete raw ASR, with “Inserted without cleanup” after confirmed delivery. Failed, empty, or known-incomplete recognition never reports successful delivery. Partial available text may be recovered temporarily.

`TextInsertionService` captures the external PID, element, optional AX window, full value and UTF-16 selection. Writable selected text is a delivery capability, not a capture prerequisite. Missing notifications are tolerated; actual app/field/window/value/selection changes are latched by supported observers and polling and revalidated immediately before writing. Secure/command fields and terminal apps are refused. A supported AX replacement is preferred; otherwise a verified Command-V menu action provides controlled Paste. There is no refocus, Enter/Send, whole-field replacement, or automatic retry. A possibly successful but unconfirmed write is reported as uncertain. Verification of the original field is bounded to 1.5 seconds and permits canonical Unicode and CRLF normalization without trimming surrounding content.

The clipboard lease snapshots all readable items/types up to 16 MiB, checks ownership, and restores only after confirmed consumption. Newer clipboard changes are preserved. An uncertain paste offers explicit Restore Clipboard while its in-memory backup remains owned. Transient/concealed/auto-generated markers advise participating clipboard managers to omit history; arbitrary clipboard managers and OS clipboard/sync services may still observe text. Process exit loses the backup. These are platform limits, not guarantees of non-propagation.

## Lifetime and meetings

Future voice input never writes a session JSON, transcript, cleaned output, destination, or restoration record. Raw/output strings remain transient. Engine-required WAVs use a private system temporary directory, outside the meeting archive, with one `<pid>-UUID` child per operation. Completion, cancellation, failure and Quit delete it; startup deletes owned dead-process orphans and refuses symlink roots. A deletion failure blocks another recording until cleanup succeeds. Ordinary deletion is not forensic secure erasure, and this implementation does use disk.

Each capture is limited to five minutes. Failure/uncertain delivery retains at most one 64-KiB recovery result in memory for 60 seconds. Dismissal, Copy, the next operation, app exit or timeout clears it; hiding the overlay also releases its content view. Successful delivery releases text promptly. Metrics are numeric/status-only; normal execution does not log field, clipboard, transcript or audio content. Explicit developer diagnostics report only their known synthetic utterances.

The menu bar provides microphone, shortcut, language, Auto Insert and AI Cleanup. Cleanup remains OFF for existing OFF preferences. The main window opens on demand for Meetings; there is no Recent Dictation or per-dictation navigation. Legacy archives remain on disk until the user confirms Settings → Privacy → Delete Old Dictation History. That migration deletes only dictation folders and associated audio. Meetings retain audio, immutable raw versions, corrected derivatives, summaries, recovery and full exports. Quit cancels/discards active voice input while saving an active meeting.

## Backtracking

The same cleanup model receives the full utterance and a conservative correction reference. `BacktrackingPolicy` independently identifies supported superseded spans; `EditingPolicy` checks final token order/content, identifiers, numbers, negation, scope and quoted literals. Clear corrections can replace a number or negation; unrelated removal cannot. Ambiguous cues stay content. These checks are conservative heuristics, not a proof of semantic equivalence. Unsupported rewrites deliver complete raw ASR when the target is safe. Cleanup OFF never applies the reference as hidden processing. Meeting raw transcription and summary policy are unchanged.

## Actual checks and remaining limits

| Check | Evidence in this build |
| --- | --- |
| Swift tests | 22 passed, zero failures: the original 19 regressions plus caret/display placement, full-field delayed verification and operation invalidation |
| Native offline ASR / Cleanup OFF | Six synthetic ASR fixtures plus digital silence with all networking denied; zero editor calls, raw output unchanged, no dictation archive growth, temporary audio removed |
| Meeting persistence/export/recovery | Accelerated one-hour two-source writer fixture (not a live one-hour call), complete exports and crash recovery passed; migration test preserves meeting metadata and audio byte for byte |
| Cleanup timeout | Local synthetic HTTP backend stalled cleanup; cancellation returned at 12.31 s, raw ASR remained complete, one editor call, temporary audio removed, archive unchanged. The target was unsafe/unverified, so no external insertion was attempted |
| Repeated failures, silence, recovery expiry and restart | Four synthetic transient ASR operations in one native process: zero editor calls and archive growth, all temporary audio removed, silence clears recovery and never inserts, real 61-second expiry releases recovery, synthetic dead-process orphan removed on restart |
| Native meeting text regression | Existing pinned Gemma/local Swift actor with external networking denied: mixed-language cleanup unchanged; summary evidence validated, Tuesday review decision retained, conditional Friday/QA discussion and unresolved Payload CMS issue retained, no owner/action assignment invented; cleanup 6.80 s, summary 16.18 s |
| Quit during real microphone capture | Capture still Recording after three seconds, ASR not started, actual temporary directory present; SIGTERM through AppDelegate exited normally, deleted that directory, and created zero archive records |
| Fixed Unicode / automatic Paste browser attempt | Prepared public MDN textarea in Codex browser. Actual macOS frontmost app remained Firefox, whose current field lacked verifiable value/selection; safely refused. This is not positive browser/Paste compatibility evidence |
| TextEdit selected Unicode fixture | User confirmed success in the earlier stable signed build. NOT RUN as positive evidence for the new complete speech/cleanup/transient pipeline |
| Live microphone → native editor, OFF and ON | NOT RUN / awaiting physical user test of current bundle |
| Live microphone → user's browser/composer | NOT RUN / awaiting physical user test; no positive Firefox, Chrome, VS Code, Notes, ChatGPT, Claude or WhatsApp claim |
| Empty/caret/selection and no submission in real targets | Core replacement tests pass; current actual cross-app coverage remains NOT RUN |
| Successful supported Paste fallback | Implemented and clipboard logic tested; actual confirmed automatic Paste remains NOT RUN |
| Changed focus / denied permission / secure target / uncertainty | Policy/stale/permission tests and safe real-target rejection; actual secure-field, all focus-change scenarios and uncertain-write integration remain NOT RUN |
| Live dual-source meeting | NOT RUN for this change. Screen/system capture preflight was false in early bundle diagnostics and true in later explicit native diagnostics; this difference does not prove current live call capture |

The browser controller rejected `file://` fixtures (HTTP/HTTPS only); it was not bypassed. A public HTTPS textarea was used separately. Automatic approval review later denied a full Firefox AX refresh because the signed-in browser contained unrelated private/health tabs. User-assisted disposable-field tests avoid reading those tabs. A full preference-database export was also denied; it was not executed or bypassed. App-targeted automation can change a background control while macOS still reports another active application. Physical shortcut triggering and stable actual foreground focus require a user-assisted check. Do not weaken focus validation to make these probes appear successful.

Stop-to-insert latency is NOT MEASURED because this build has no confirmed complete external speech delivery yet. The timeout fixture took 15.41 s from synthetic recognition start to recovery (ASR 3.08 s plus cleanup 12.31 s); that is stop-to-outcome, not stop-to-insert. Fixed-text refusal took 0.06 ms and says nothing about speech latency. The full definition of done remains unverified until native and browser live delivery succeed without Copy or window switching.


### Full synthetic cleanup evaluation

All 13 final outputs below were inspected; all passed the independent fidelity check. These are text fixtures through the existing local model, not live microphone recognition or external insertion. The final bounded run used localhost-only networking. The first negation run retained superseded wording and was rejected; an explicit polarity-restatement prompt example corrected that behavior on subsequent runs.

| Current utterance | Complete output | Cleanup seconds |
| --- | --- | --- |
| Meetingnya Senin, eh maksudku Selasa jam dua. | Meetingnya Selasa jam dua. | 6.74 |
| Send it to Audrey—sorry, to Kevin. | Send it to Kevin. | 4.62 |
| Push ke production—bukan, ke staging aja. | Push ke staging aja. | 5.31 |
| Let's meet at four—actually, at five. | Let's meet at five. | 4.25 |
| Budgetnya 5 juta, eh maksudku 500 ribu. | Budgetnya 500 ribu. | 5.69 |
| Jangan deploy ke staging—sorry, I meant deploy ke staging. | Deploy ke staging. | 4.40 |
| Selesaikan QA dulu. Simpan report 16 MB. Meetingnya Senin, eh maksudku Selasa jam dua. | Selesaikan QA dulu. Simpan report 16 MB. Meetingnya Selasa jam dua. | 5.43 |
| I actually prefer the first option. | I actually prefer the first option. | 4.51 |
| Bukan lima juta, tapi lima ratus ribu. | Bukan lima juta, tapi lima ratus ribu. | 3.74 |
| Jangan deploy ke production. Push ke staging aja. | Jangan deploy ke production. Push ke staging aja. | 5.03 |
| Kalau QA lolos, mungkin Jumat bisa release. | Kalau QA lolos, mungkin Jumat bisa release. | 4.54 |
| Type the words "sorry, I meant" in the document. | Type the words "sorry, I meant" in the document. | 4.76 |
| Meetingnya Senin, bukan, yang Selasa jam dua. | Meetingnya Selasa jam dua. | 4.27 |

Observed cleanup latency: 3.74–6.74 s, median 4.62 s in this bounded run. The earlier warm v1 comparison in VALIDATION.md is historical, not the latency of this prompt.

## Reproduction and handoff

Build/run the stable signed bundle with `./script/build_and_run.sh --verify`; the executable is `dist/talkie.app/Contents/MacOS/talkie`. The menu bar is the default workflow. Normal macOS permissions apply; Settings has an explicit Accessibility action. Never edit permission databases.

For physical tests use a disposable native document and a browser textarea/composer with no submission. Start with `BEGIN [replace me] END`, select the bracketed span, use the configured shortcut to start/stop, and speak a clear correction. Check the entire result, surrounding text, and no send action. Repeat with an empty field and a middle caret, then move focus/selection during processing to check refusal. Repeat OFF and ON; do not use private messages or meetings as fixtures.

`script/verify_dictation_insertion.sh off 20` (or `on` with the pinned runtime) uses a signed isolated app instance and existing synthetic TTS files. It reports safe preview as unsuccessful insertion. `--fixed-insertion-test --force-paste` separates fixed Unicode insertion from ASR. `--backtracking-evaluation` inspects full known utterance output through the existing model. `--transient-lifecycle-test` checks repeated transient operations, silence and actual recovery expiry. None proves live speech or physical shortcut compatibility. Diagnostics, audio, models and local reports remain ignored by Git.

The older [VALIDATION.md](VALIDATION.md) records historical results; its saved dictation, preview-only cleanup, and strict notification rules do not describe this build.
