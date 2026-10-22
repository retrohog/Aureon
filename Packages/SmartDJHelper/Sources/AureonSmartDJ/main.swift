import Foundation
import HuggingFace
import MLXGuidedGeneration
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

// AureonSmartDJ: a tiny language-model server on stdin/stdout, one JSON object per line.
//
//   → {"op":"load","model":"mlx-community/Qwen2.5-0.5B-Instruct-4bit"}
//   ← {"event":"progress","fraction":0.4,"message":"Downloading the model"}      (zero or more)
//   ← {"event":"loaded","seconds":1.8}                                            or {"event":"error","message":"…"}
//   → {"op":"generate","id":7,"system":"…","user":"…","schema":{…JSON schema…},"maxTokens":200}
//   ← {"event":"result","id":7,"text":"{\"ids\":[3,9]}","tokens":12,"seconds":0.4}   or {"event":"error","id":7,"message":"…"}
//   → {"op":"unload"}        ← {"event":"unloaded"}   (then the program exits)
//   → {"op":"ping"}          ← {"event":"pong"}
//
// The output is constrained by the schema (grammar-guided decoding), so it is always valid JSON of the requested shape.

setvbuf(stdout, nil, _IOLBF, 0)

func send(_ o: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return }
    print(s); fflush(stdout)
}

final class Server: @unchecked Sendable {
    var container: ModelContainer?

    func load(model: String) async {
        let t0 = Date()
        do {
            send(["event": "progress", "fraction": 0.0, "message": "Preparing the model"])
            let last = LastFraction()
            let c = try await #huggingFaceLoadModelContainer(configuration: ModelConfiguration(id: model)) { progress in
                let f = progress.fractionCompleted
                if last.shouldReport(f) { send(["event": "progress", "fraction": f, "message": f < 1 ? "Downloading the model" : "Loading the model"]) }
            }
            container = c
            send(["event": "loaded", "seconds": Date().timeIntervalSince(t0)])
        } catch {
            send(["event": "error", "message": "Could not load the model: \(error.localizedDescription)"])
        }
    }

    func generate(id: Int, system: String, user: String, schema: Any, maxTokens: Int) async {
        guard let container else { send(["event": "error", "id": id, "message": "The model is not loaded"]); return }
        let t0 = Date()
        do {
            let schemaData = try JSONSerialization.data(withJSONObject: schema)
            let schemaText = String(decoding: schemaData, as: UTF8.self)
            let (text, tokens) = try await container.perform { context -> (String, Int) in
                let tokenizer = context.tokenizer
                let gv = TokenizerVocabExtractor.extractForGrammar(from: tokenizer)
                let gt = try GrammarTokenizer(vocab: gv.vocab, vocabType: gv.vocabType, eosTokenId: Int32(tokenizer.eosTokenId ?? 0))
                let constraint = try GrammarConstraint(tokenizer: gt, jsonSchema: schemaText, fastForward: true, hostTokenizer: tokenizer)
                let input = try await context.processor.prepare(input: UserInput(chat: [.system(system), .user(user)]))
                var out = ""
                let n = try GuidedGenerationLoop.run(input: input, context: context, constraint: constraint, maxTokens: maxTokens, vocabSize: gt.vocabSize) { delta in out += delta; return true }
                return (out, n)
            }
            send(["event": "result", "id": id, "text": text, "tokens": tokens, "seconds": Date().timeIntervalSince(t0)])
        } catch {
            send(["event": "error", "id": id, "message": "Generation failed: \(error.localizedDescription)"])
        }
    }
}

final class LastFraction: @unchecked Sendable {
    private let lock = NSLock(); private var last = -1.0
    func shouldReport(_ f: Double) -> Bool { lock.lock(); defer { lock.unlock() }; if f - last >= 0.02 || f >= 1 { last = f; return true }; return false }
}

let server = Server()
while let line = readLine(strippingNewline: true) {
    guard let d = line.data(using: .utf8), let msg = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let op = msg["op"] as? String else {
        send(["event": "error", "message": "unreadable request"]); continue
    }
    switch op {
    case "ping": send(["event": "pong"])
    case "load": await server.load(model: msg["model"] as? String ?? "mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    case "generate":
        await server.generate(id: msg["id"] as? Int ?? 0, system: msg["system"] as? String ?? "", user: msg["user"] as? String ?? "", schema: msg["schema"] ?? [:], maxTokens: msg["maxTokens"] as? Int ?? 256)
    case "unload":
        server.container = nil
        send(["event": "unloaded"])
        exit(0)
    default: send(["event": "error", "message": "unknown request \(op)"])
    }
}
