# Local validation — 2026-10-09

This is a historical record of the initial MVP. The [current transient voice-input contract and validation](SYSTEM_WIDE_DICTATION.md) supersedes saved dictation history, preview-only cleanup and strict AX-notification requirements. Results below apply to the earlier build unless repeated in the current record.

Target inspected directly: macOS 26.5.2 (25F84), arm64 Apple M5, 24 GiB RAM, roughly 314 GiB disk free at setup, Xcode 26.6 (17F113), Swift 6.3.1. The GitHub remote was successfully queried twice as empty before creating `main`; this is a new repository, not an unrelated-history merge. No hosted CI/release workflow was added.

## Executed checks

| Check | Actual result |
| --- | --- |
| Local Swift tests | 7 tests, zero failures: full Unicode/marker exports, failed/gap intervals, JSON/SRT, immutable raw/correction links, summary source history, cleanup policy, evidence IDs, 400-segment batching, file permissions, deletion retaining transcript |
| Native package/build/run | SwiftPM build, bundle signature verification, normal bundle launch and native SwiftUI screens passed |
| Permissions | Microphone authorized, AX trust and screen capture true in ASR/text/capture diagnostics; later ad hoc rebuild lost AX trust, prompting stable signing repair described below |
| Actual ASR | Six macOS TTS recordings, empty dictionary, multilingual auto/transcribe mode; reference and full outputs retained in public synthetic report |
| Silence | Five-second digital-silence fixture: zero segments and detected-silence state; this fixed an observed initial hallucination |
| Cleanup OFF pipeline | Actual AppStore transcription of synthetic speech, networking denied, original matched saved ASR, zero editor calls, complete raw export passed. An earlier run also had the owned Ollama server stopped |
| Settings persistence | Reconstructed preferences from isolated UserDefaults suite retained OFF and Auto/Mixed |
| Export/history | Beginning/middle/end markers, failed chunk and capture gap, all known segments preserved; raw versions survived corrections/round trip and summary source link remained on older version |
| Accelerated long-session writer | 60-minute two-source input fixture at 48 kHz stereo; 481 readable mono 16 kHz chunks, maximum 969,684 bytes, total 462,448,544 bytes, timeline 3599.996 s; pause + mute markers retained; last-source end difference about 6.94 ms |
| Long-session timing/memory | Latest writer fixture took 10.67 s of wall time. Combined offline ASR/pipeline/writer diagnostic took 23.26 s; maximum resident set 360,480,768 bytes, physical-footprint peak 282,166,448 bytes reported by macOS time. This is the app process, not GPU/ANE allocations or total-system inference RAM |
| Recovery | Synthetic unlisted WAV and transcription draft recovered as incomplete with unknown-tail marker. A live diagnostic interrupted during a test collision left private chunks in ignored local storage; no real audio was published |
| Actual ScreenCaptureKit smoke test | 13.53-second live capture without sound playback: both sources produced two readable mono 16 kHz chunks, microphone 8.373 s and system 11.080 s of saved audio; three pause/mute markers and one source-start gap. No transcription of that ambient audio was performed |
| Native local text client | Gemma cleanup and v2 summary through the actual Swift actor, with external networking denied and only localhost:11434 allowed; digest/runtime checks and reference validation passed. Cleanup preserved mixed language (6.60 s); summary retained Tuesday-at-two decision, conditional Friday discussion, unresolved Payload CMS issue, and no invented owner (14.52 s) |
| Online data routes | Source audit: only explicit model downloads and loopback text requests; strict local tokenizer, no ASR fallback, rejected text redirects/proxies/cloud identities. A during-ASR socket inspection observed no app outbound connection. This is not a full packet-capture proof for every OS/framework path |

The accelerated writer fixture is not a one-hour live recording, and the short ScreenCaptureKit test is not a controlled online call. Writer RSS does not establish memory use for a one-hour ASR/summary job. Fixed-language modes and actual human accented speech need further evaluation.

## ASR output observations

Whisper returned “stagging” for staging, “Piloat CMS” for Payload CMS, and “KIA” for QA in the synthetic mixed clip. English preserved Next.js 16 and the 16 versus 60 distinction; Indonesian preserved the 500 ribu versus 5 juta distinction and negation. The short technical-name clip preserved SwiftUI, CoreML, PostgreSQL, and Rina. These are permitted TTS samples, not a representative human-speech benchmark. Full reference/output pairs are in [offline-verification.json](fixtures/offline-verification.json).

First-ever Core ML prewarm took 64.73 s. A later network-denied cached-process start took 2.85 s; subsequent clips in that run took about 0.82–1.04 s. The latest public report records 3.82 s for the first clip and 0.87–1.90 s for later clips, while another capture diagnostic was running. Recognition is post-recording, with no verbatim/latency guarantee. Dictionary hints were deliberately empty to expose baseline errors.

## Text model comparison

Same ten raw-text fixtures, Ollama 0.40.1, temperature 0, seed 42, 8192 context, 2048 output limit. Both runtime/model metadata explicitly support `think: false`; thinking content was empty. Keep-alive during the comparison enabled warm measurements; production uses zero. Allocations were read from `/api/ps`, not guessed from parameter count or download size.

| Candidate | Cold cleanup | Warm median | Runtime resident allocation | Global memory-pressure free snapshot | Observed quality |
| --- | --- | --- | --- | --- | --- |
| qwen3.5:9b-q4_K_M | 9.00 s | 2.39 s | 5,765,165,219 bytes | 21% | Translated the English part of mixed-language fixture 7 into Indonesian: critical fidelity failure; excluded from default automatic insertion |
| gemma4:e4b-it-qat | 5.09 s | 1.07 s | 3,097,378,159 bytes | 27% | Preserved code-switching, scope, names/numbers/negation in these ten cases; did not flag the ambiguous Monday→Tuesday correction for review |

Initial `grounded-summary-v1` outputs showed proposal/decision classification errors. After explicit decision/conditional grounding instructions in **v2**, Gemma kept the Tuesday decision and unknown owner, leaving conditional Friday release under discussion; Qwen still placed conditional statements under decisions. V2 Python comparison latencies were 22.09 s (Gemma) and 35.60 s (Qwen). Native Swift verification additionally ran the production schema/reference validation. No bounded-thinking comparison or constrained 4B candidate was run; the 24 GiB Mac did not require a downgrade. Both cleanup and summary initially select Gemma. In this historical build cleanup remained preview-only for every candidate. Current behavior is independently accepted automatic cleanup, with complete raw ASR on rejection/failure; see the current record above.

Exact tags, digests, reported parameter/quantization details, prompt/runtime/decoding settings and sizes: [model-config.json](model-config.json). Actual outputs: [cleanup and v1 summary](fixtures/text-model-evaluation.json), [v2 summary](fixtures/summary-v2-evaluation.json), [native client](fixtures/native-text-verification.json). The original v1 record is preserved; rerunning evaluation scripts uses the current v2 prompt.

## Compatibility and remaining live checks

| Surface / behavior | Status |
| --- | --- |
| Native talkie main/settings/meeting setup | Rendered and inspected through macOS UI automation |
| Installed model configuration | Speech model installed; Settings → Models successfully verified and pinned the selected Gemma digest for both cleanup and summary; Cleanup remains OFF |
| TextEdit synthetic selection | Initial fallback identified lost Accessibility trust after ad hoc rebuild. After stable developer signing and user regrant, the user confirmed selection replacement; AX inspection confirmed the inserted “talkie fixture — café 日本語” text. Exact caret/surrounding-content assertions still need a controlled physical test |
| Focus/selection safety | Changed/unverified target returned preview without replacement or retry. Automated background-window probe correctly refused the actual frontmost Terminal; it did not alter the TextEdit selection |
| Global shortcut | Carbon registration and physical-key-triggered Unicode insertion reached the app. UI automation's app-targeted input did not change the actual frontmost app reliably. Toggle/hold/release/Escape timing still needs a clean physical dictation test |
| Clipboard | Automatic insertion code has no pasteboard access; Copy is explicit. Concurrent clipboard change during a successful cross-app insertion has not been exercised |
| Browser text field | Not run |
| Code-editor text field | Not run |
| Messaging composer | Not run; no test message was sent |
| Secure field / embedded command input | Refusal implemented by AX role/subrole/ancestor checks and terminal bundle deny list; live field tests not run |
| Headphone controlled call, independent remote/local speech | Not run: output remained Studio Display Speakers; headphone arrangement and permitted call participant/sample were not available |
| Speaker echo | Not run; no perfect echo-cancellation claim |
| Live device switch, sleep, capture-permission revocation, disk-full | Error/interruption handling implemented; these fault injections not run |
| Offline live capture and full app flow | File ASR/export and loopback text separately verified under process network restrictions; live capture ran online. Physical Wi-Fi-off end-to-end call/insertion flow not run |

The user regranted Accessibility and confirmed selection insertion for the stable signed bundle. Remaining prerequisites are user-assisted physical caret/other-app checks and a permitted headphone call. Run the native editor caret test, then a disposable browser/code/messaging field with surrounding text and Unicode. Move selection/focus mid-dictation and verify preview. Use headphones with a consenting participant, speak distinct local/remote marker phrases, pause/resume/mute the recorder, then inspect both sources and full exports. Never use a private meeting as a test fixture or submit/send a composer automatically.

## Local reproduction and signing

Use the commands in the README. `verify_offline.sh` denies all app networking after downloads; `verify_text_service.sh` permits only localhost:11434. Neither changes global networking. Both use the explicit diagnostic path of the bundled executable and write only ignored local artifacts. Normal use launches the `.app` bundle.

The first ad hoc designated requirement was a code hash, so a rebuild invalidated its Accessibility trust. The final build reuses the Mac's existing Apple Development certificate with a stable identifier/certificate requirement and no timestamp network request. No private key material, certificate owner details, or identity configuration is committed. On a Mac with no usable local signing identity the script falls back to ad hoc and documents the repeated permission requirement. No entitlement, TCC database edit, security bypass, notarization or paid publication was introduced.
