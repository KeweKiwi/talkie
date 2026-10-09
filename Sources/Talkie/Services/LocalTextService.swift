import Foundation
import TalkieCore

actor LocalTextService {
    struct ModelIdentity { var name: String; var digest: String; var runtime: String }
    struct CleanupResponse: Decodable { var text: String; var needs_review: Bool }
    static let allowedModels = ["qwen3.5:9b-q4_K_M", "gemma4:e4b-it-qat"]
    private let base = URL(string: "http://127.0.0.1:11434")!
    private let session: URLSession
    private var busy = false
    private(set) var cleanupCalls = 0
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180; config.timeoutIntervalForResource = 240
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }
    private func request(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent(path)); request.httpMethod = body == nil ? "GET" : "POST"
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard data.count < 4 * 1024 * 1024 else { throw TalkieError.message("Local model response exceeded the safe size limit.") }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TalkieError.message("Local Ollama request failed. Start a compatible local-only runtime and install the selected model. Audio and transcript are preserved.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TalkieError.message("Invalid local runtime response.") }
        return object
    }
    func identity(_ model: String, pinnedDigest: String = "") async throws -> ModelIdentity {
        guard Self.allowedModels.contains(model) else { throw TalkieError.message("Select an explicitly supported local model; cloud models are blocked.") }
        let tags = try await request("api/tags")
        guard let models = tags["models"] as? [[String: Any]], let installed = models.first(where: { $0["name"] as? String == model }), let digest = installed["digest"] as? String else { throw TalkieError.message("The selected model is not installed. talkie never substitutes another model.") }
        if !pinnedDigest.isEmpty && pinnedDigest != digest { throw TalkieError.message("Model digest changed. Review and pin the installed version in Settings.") }
        let info = try await request("api/show", body: ["model": model])
        guard info["remote_host"] == nil, info["remote_model"] == nil else { throw TalkieError.message("Remote models are blocked.") }
        if let thinking = info["thinking"] as? [String: Any], let values = thinking["values"] as? [Any], !values.contains(where: { ($0 as? Bool) == false }) {
            throw TalkieError.message("This model/runtime cannot use supported non-thinking mode.")
        }
        let runtime = try await request("api/version")["version"] as? String ?? "unknown"
        guard runtime == "0.40.1" else { throw TalkieError.message("This configuration was validated with Ollama 0.40.1. Use the pinned project-local runtime; no silent runtime substitution.") }
        return ModelIdentity(name: model, digest: digest, runtime: runtime)
    }
    private func finalJSON(identity: ModelIdentity, prompt: String, data: Any, schema: [String: Any]) async throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        guard payload.count <= 6000 else { throw TalkieError.message("Input exceeds the conservative context budget; full transcript export remains available.") }
        let response = try await request("api/chat", body: [
            "model": identity.name, "stream": false, "think": false, "keep_alive": 0,
            "format": schema, "messages": [["role": "system", "content": prompt], ["role": "user", "content": String(decoding: payload, as: UTF8.self)]],
            "options": ["temperature": 0, "seed": 42, "num_ctx": 8192, "num_predict": 2048]
        ])
        guard response["done"] as? Bool == true, response["done_reason"] as? String != "length",
              let message = response["message"] as? [String: Any], let text = message["content"] as? String,
              !text.isEmpty, !text.contains("<think>") else { throw TalkieError.message("Local model returned an incomplete answer. Original data is preserved.") }
        guard let evaluated = response["prompt_eval_count"] as? Int, evaluated < 6000 else { throw TalkieError.message("Measured context budget exceeded; result rejected.") }
        return Data(text.utf8)
    }
    func cleanup(_ original: String, model: String, digest: String) async throws -> (CleanupResponse, ModelIdentity) {
        cleanupCalls += 1
        guard !busy else { throw TalkieError.message("Another local text task is running.") }; busy = true; defer { busy = false }
        guard !digest.isEmpty else { throw TalkieError.message("Verify and pin the selected model digest in Settings before text inference.") }
        let identity = try await identity(model, pinnedDigest: digest)
        let schema: [String: Any] = ["type": "object", "properties": ["text": ["type": "string"], "needs_review": ["type": "boolean"]], "required": ["text", "needs_review"], "additionalProperties": false]
        let data = try await finalJSON(identity: identity, prompt: EditingPolicy.prompt, data: ["raw_asr": original, "permitted_correction_reference": BacktrackingPolicy.reference(original)], schema: schema)
        let result = try JSONDecoder().decode(CleanupResponse.self, from: data)
        guard !result.text.isEmpty else { throw TalkieError.message("Cleanup returned no text; use the original.") }
        return (result, identity)
    }
    func summarize(_ transcript: TranscriptVersion, model: String, digest: String, language: String, startedAt: Date, timeZone: String, progress: @escaping @Sendable (String) -> Void) async throws -> SummaryVersion {
        guard !busy else { throw TalkieError.message("Another local text task is running.") }; busy = true; defer { busy = false }
        guard !digest.isEmpty else { throw TalkieError.message("Verify and pin the selected model digest in Settings before text inference.") }
        let identity = try await identity(model, pinnedDigest: digest)
        let batches = try SummaryPolicy.batches(transcript, characterBudget: 4000)
        guard !batches.isEmpty else { throw TalkieError.message("No transcript segments to summarize.") }
        var partials: [GroundedSummary] = []
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation(); progress("Summarizing part \(index + 1) of \(batches.count)")
            let segments: [[String: Any]] = batch.map { ["id": $0.id, "source": $0.source.rawValue, "start": $0.start, "end": $0.end, "text": $0.text, "uncertain": $0.uncertain] }
            let payload: [String: Any] = ["language": language, "recording_start_utc": ISO8601DateFormatter().string(from: startedAt), "time_zone": timeZone, "partial_transcript": !transcript.accountedFor, "segments": segments]
            let data = try await finalJSON(identity: identity, prompt: SummaryPolicy.prompt, data: payload, schema: Self.summarySchema)
            let result = try JSONDecoder().decode(GroundedSummary.self, from: data); try result.validate(against: transcript); partials.append(result)
        }
        // Bounded pairwise reduction. Never discard an input to fit the context window.
        while partials.count > 1 {
            var next: [GroundedSummary] = []
            for index in stride(from: 0, to: partials.count, by: 2) {
                try Task.checkCancellation()
                if index + 1 == partials.count { next.append(partials[index]); continue }
                progress("Merging grounded summaries (\(partials.count) remaining)")
                let serialized = try JSONEncoder().encode([partials[index], partials[index + 1]])
                let payload: [String: Any] = ["language": language, "partial_transcript": !transcript.accountedFor, "partial_summaries": try JSONSerialization.jsonObject(with: serialized)]
                let data = try await finalJSON(identity: identity, prompt: SummaryPolicy.prompt, data: payload, schema: Self.summarySchema)
                let merged = try JSONDecoder().decode(GroundedSummary.self, from: data); try merged.validate(against: transcript)
                let originalRefs = Set((partials[index].allItems + partials[index + 1].allItems).flatMap(\.references))
                guard originalRefs.isSubset(of: Set(merged.allItems.flatMap(\.references))) else { throw TalkieError.message("Merge dropped evidence references; summary rejected. Export the complete transcript or retry.") }
                next.append(merged)
            }
            partials = next
        }
        return SummaryVersion(transcriptID: transcript.id, model: identity.name, digest: identity.digest, runtime: identity.runtime, promptVersion: SummaryPolicy.version, language: language, content: partials[0])
    }
    static var summarySchema: [String: Any] {
        let item: [String: Any] = ["type": "object", "properties": ["text": ["type": "string"], "references": ["type": "array", "items": ["type": "string"]], "owner": ["type": ["string", "null"]], "deadline": ["type": ["string", "null"]]], "required": ["text", "references", "owner", "deadline"], "additionalProperties": false]
        let keys = ["overview", "discussion", "decisions", "actions", "questions"]
        return ["type": "object", "properties": Dictionary(uniqueKeysWithValues: keys.map { ($0, ["type": "array", "items": item] as [String: Any]) }), "required": keys, "additionalProperties": false]
    }
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
