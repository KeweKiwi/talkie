# Third-party software and model notices

Licenses were inspected separately from runtime quality. Models are downloaded explicitly and are not included in Git or an automatic release. Required software notices are also copied into `talkie.app/Contents/Resources/licenses`.

| Component / exact identity | Verified license | Preserved notice / primary source |
| --- | --- | --- |
| Argmax OSS Swift 1.1.1 (`1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`), WhisperKit OSS product only | MIT, with vendored component notices | [MIT](docs/licenses/Argmax-MIT.txt), [NOTICES](docs/licenses/Argmax-NOTICES.txt), [upstream](https://github.com/argmaxinc/argmax-oss-swift/tree/1.1.1) |
| Swift Argument Parser 1.8.2 | Apache-2.0 | [License](docs/licenses/SwiftArgumentParser-Apache-2.0.txt), [upstream](https://github.com/apple/swift-argument-parser) |
| OpenAI Whisper and multilingual large-v3 weights/tokenizer | MIT | [License](docs/licenses/Whisper-MIT.txt), [upstream](https://github.com/openai/whisper), [tokenizer](https://huggingface.co/openai/whisper-large-v3) |
| Argmax converted `openai_whisper-large-v3-v20240930_626MB`; whisperkit-coreml revision `0f63a7800b00dd0226abd051b906c246e1907482` | MIT, verified model repository metadata | [model repository](https://huggingface.co/argmaxinc/whisperkit-coreml), [exact download manifest](Resources/asr-manifest.json) |
| Ollama 0.40.1 official macOS runtime | MIT | [License](docs/licenses/Ollama-MIT.txt), [official release](https://github.com/ollama/ollama/releases/tag/v0.40.1) |
| `qwen3.5:9b-q4_K_M`, evaluated digest in model config | Apache-2.0 | [License](docs/licenses/Qwen-Apache-2.0.txt), [installed model license](docs/licenses/qwen-installed-model.txt), [Qwen card](https://huggingface.co/Qwen/Qwen3.5-9B), [Ollama tag](https://ollama.com/library/qwen3.5:9b-q4_K_M) |
| `gemma4:e4b-it-qat`, evaluated digest in model config | Apache-2.0, verified for **Gemma 4**, not assumed from older Gemma generations | [installed model license](docs/licenses/gemma-installed-model.txt), [Google model card](https://ai.google.dev/gemma/docs/core/model_card_4), [Ollama tag](https://ollama.com/library/gemma4:e4b-it-qat) |

The Apple frameworks/SDK are supplied by the user's macOS/Xcode installation. No paid Argmax Pro SDK/API is linked. Handy's public implementation was inspected for patterns, but no Handy source was copied or linked. There is no trial-gated dependency, model-account gate, or billing bypass. License verification does not imply model-output accuracy. Preserve notices when redistributing dependencies or weights; this project does not create a distribution service.
