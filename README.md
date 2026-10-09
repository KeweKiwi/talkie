# talkie

A personal macOS dictation and meeting-notes app. Speech recognition, optional text cleanup, and summaries run locally. Full transcript export works independently of Ollama. Visible branding is **talkie**.

Requires Apple Silicon, macOS 15+, and Xcode with its macOS SDK. Verified on macOS 26.5.2, Apple M5, 24 GiB RAM, Swift 6.3.1/Xcode 26.6. This is a usable local MVP with remaining live compatibility checks documented in [validation](docs/VALIDATION.md); it is not a promise of universal insertion compatibility or error-free transcription.

## Build and first setup

```sh
git clone https://github.com/KeweKiwi/talkie.git
cd talkie
./script/build_and_run.sh
```

The Run button uses the same script. It builds the pinned Swift package and a signed bundle at `dist/talkie.app`, with stable identifier `co.kewekiwi.talkie`. It reuses a single existing Apple Development identity when available; set `TALKIE_SIGNING_IDENTITY` explicitly if you have multiple identities. No keys are created/imported. Otherwise it falls back to ad hoc signing, whose changed code hash can require regranting Accessibility after a rebuild. Launch the bundle, rather than the naked Swift executable, for ordinary use. Keep this installation path stable for macOS permissions. No new paid membership or notarization is introduced for this personal build.

The script uses `/Applications/Xcode.app/Contents/Developer` without changing global `xcode-select`. Override `DEVELOPER_DIR` for another Xcode installation. Swift dependency resolution needs the network initially. The executable targets macOS 15; Intel has not been tested or validated.

In Settings → Models, explicitly **Download Speech Model**. The model is the pinned multilingual Large v3 Turbo Core ML candidate, approximately 0.63 GB of weights plus tokenizer and compilation/cache space. Download progress advances per file. A command-line alternative is `python3 script/download_asr.py`. Exact revisions, file sizes, and available LFS hashes are in [Resources/asr-manifest.json](Resources/asr-manifest.json).

In Settings → General, request Microphone and Accessibility. Online meetings additionally require **Screen & System Audio Recording** under System Settings → Privacy & Security. macOS owns these grants; talkie does not edit permission databases. A relaunch may be necessary after granting capture access. Accessibility is optional when you use preview and manual Copy. Capture consent is requested separately in the meeting setup UI.

## Dictation

In your editor, press **Control + Option + Space**, speak, then press it again. Settings allow another key/modifier combination and hold-to-talk. Escape cancels dictation or transcription, retaining recoverable data. Dictation is blocked while a meeting is recording. The nonactivating recording overlay leaves the intended editor in focus.

**AI Cleanup starts OFF** and persists across restarts. OFF returns saved ASR text directly, with no editor model call or Ollama requirement. ASR itself can add punctuation or normalize speech; this is not guaranteed literal speech. Recognition defaults to **Auto/Mixed**; Bahasa Indonesia and English are selectable recognition hints, never translation commands. Dictionary entries are ASR hints, not post-recognition replacement rules.

Insertion requires a verified supported Accessibility text field, unchanged app/field/selection/content, and selection/focus observation support. It replaces the selection or inserts at the caret using `AXSelectedText`. It never presses Enter or Send. Secure fields, terminals, ambiguous command inputs, unsupported editors, and changed targets use preview/Copy. An uncertain insertion is never retried automatically. Automatic insertion does not touch the clipboard; an explicit Copy intentionally replaces it.

Starting from the main app produces a preview. Results retain **Show Original / Use Original**, and can be reviewed or edited before copying. Cleanup ON is deliberately **preview-only**: model outputs require review because a compared candidate changed language and automated fidelity checks are not proof of equivalence. The cleanup setting is captured at recording start and does not rewrite past results.

## Meeting notes

Choose Meetings, enter a title, confirm permission to record, then Start. Microphone-only uses the default system input. Online recording uses one ScreenCaptureKit stream with separate microphone and system/application-audio outputs. Select an application or all system audio excluding talkie. Application capture covers that app, potentially multiple tabs/windows, rather than one browser tab. No screen output is registered and no screen frames are read or saved.

The app shows elapsed time, source levels, selected sources, Pause/Resume, recorder microphone mute, and Stop. Recorder mute is independent of a meeting app's mute. Playback routing is left to macOS. Use headphones for the initial live test; speaker echo cancellation has not been demonstrated.

Stop saves audio first. **Transcribe Saved Audio** creates a raw transcript version. Every available segment, source, timestamp, and pause/missing/failed marker is available through **Copy Full Transcript** and **Export Full Transcript** (UTF-8 Markdown/Text, JSON, SRT). Those actions work with Ollama stopped and do not generate a summary. **Copy AI Instructions** only prepares text for manual external use; the app does not submit it anywhere.

**Correct Transcript** creates a derivative linked to its source; **Create New ASR Version** retains previous raw versions. **Summarize Locally** is independent and links its result to the exact transcript version and model settings. Older-source and partial-transcript summaries are marked. Evidence IDs are validated, but check claims against the transcript. Summaries can be edited, copied, and exported locally.

## Optional local text models

Core recording/transcription/export does not depend on this setup. The evaluated configuration uses a project-local Ollama **0.40.1** runtime, without changing a preexisting Ollama installation:

```sh
./script/setup_ollama_runtime.sh
./script/start_ollama.sh
# In another terminal, explicit downloads of both evaluated candidates:
./script/setup_text_models.sh
```

The server binds only `127.0.0.1:11434`, disables Ollama cloud features, and limits loaded models to one. Do not expose the port remotely. If another server already occupies it, stop that server deliberately before starting the pinned runtime. Then Settings → Models → **Verify & Pin Installed Digests**. Cleanup and summary selections are independent; both initially select `gemma4:e4b-it-qat`. A changed digest/runtime is rejected, rather than silently substituting a model. See [model configuration](docs/model-config.json) and [actual evaluation outputs](docs/fixtures/text-model-evaluation.json).

Both evaluated text-model downloads total about 12.7 GB; you may keep only the chosen model. Warm cleanup medians were Gemma 1.07 s and Qwen 2.39 s. Ollama reported resident allocations of approximately 3.10 GB and 5.77 GB respectively, not their download sizes or measured total-system peak RAM. Gemma preserved code-switching better in these limited fixtures. It did not flag every ambiguous correction. Whisper, cleanup, and summaries still require human review for consequential content.

Text tasks are serialized. ASR unloads before text inference; text responses request `keep_alive: 0`. Local requests disable proxies and redirects, block cloud model identities, use supported `think: false`, and consume only final JSON content. Long summaries use bounded batches and evidence-preserving reduction; a failed/truncated/over-budget result leaves the transcript available.

## Data, recovery, and removal

Audio/model/session data lives under `~/Library/Application Support/talkie`; preferences use the app's UserDefaults domain. Session folders are mode 0700 and metadata/audio files 0600. Metadata is atomically saved and chunks are closed and synchronized before being listed. Separate source WAV chunks are approximately 15 seconds, mono 16 kHz; audio is never pushed to Git.

After interrupted recording/processing, launch recovers readable unlisted WAV chunks and saved transcription progress, with incomplete/unknown-tail markers. This is best-effort recovery, not a guarantee against disk failure. Sleep and microphone device configuration changes stop capture with an incomplete status. Review missing sources before beginning a new session.

Meetings retain audio until **Delete Audio**, which keeps transcripts/summaries. Successful Cleanup OFF dictation removes temporary WAV audio; cancelled, failed, or cleaned dictation retains it for review. **Delete Session** removes all its audio and derivatives after confirmation. Deletion is ordinary filesystem deletion, not secure erasure. Exports are separate user-owned files.

Settings → Models → **Remove Speech Model** leaves sessions intact. To remove a text model, use the pinned local runtime's `ollama rm gemma4:e4b-it-qat` or `ollama rm qwen3.5:9b-q4_K_M`; those models live in the usual Ollama storage and may be shared with other apps. Stop only the Ollama process you started. To uninstall, quit talkie, remove `dist/talkie.app` and project-local runtime `.local-data/ollama-runtime`, and optionally delete talkie's Application Support folder and preferences (`defaults delete co.kewekiwi.talkie`) after exporting anything needed. Revoke permissions in System Settings if desired. Do not remove shared Ollama data indiscriminately.

## Reproduce verification

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./script/build_and_run.sh --verify
./script/generate_fixtures.sh
./script/verify_offline.sh
# Optional, with pinned loopback Ollama running and both tags installed:
python3 script/evaluate_models.py
python3 script/evaluate_summaries.py
./script/verify_text_service.sh
```

Diagnostics consume only explicitly generated synthetic fixtures and write ignored `.local-data` reports. Offline verification denies all networking for the app process and assumes model files have already been installed; it does not toggle the Mac's Wi-Fi or reconfigure the system. Text-service verification permits only the app's loopback endpoint. See [validation and compatibility matrix](docs/VALIDATION.md), [architecture](docs/ARCHITECTURE.md), and [licenses](THIRD_PARTY_NOTICES.md).

No required account, paid inference API, subscription, backend, cloud quota, hosted build runner, automatic release upload, or recurring service fee is introduced. Initial public dependency/model downloads need an internet connection and use bandwidth; your Mac supplies storage, memory, electricity, and processing time. An external AI you manually choose has its own costs and limits.
