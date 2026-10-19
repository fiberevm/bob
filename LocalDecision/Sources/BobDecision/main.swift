import Foundation
import Clef
import MLX

/// One JSON request/response per line; a single process retains one model.
/// Only local weights are loaded. Downloading is a separate setup operation.
@main struct BobDecision {
    static func main() {
        guard (2...3).contains(CommandLine.arguments.count) else {
            FileHandle.standardError.write(Data("Usage: BobDecision <model-directory> [request.json]\nWithout a file, reads JSON lines from stdin.\n".utf8))
            exit(2)
        }
        guard Device.defaultDevice().deviceType == .gpu else {
            FileHandle.standardError.write(Data("Clef requires the Metal GPU backend.\n".utf8))
            exit(1)
        }
        // Avoid retaining large prefill temporaries across every tool review.
        Memory.cacheLimit = 256 * 1024 * 1024
        var model: Clef?
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var fileWasRead = false
        while true {
            let data: Data
            if CommandLine.arguments.count == 3 {
                if fileWasRead { break }
                fileWasRead = true
                guard let contents = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])) else {
                    FileHandle.standardError.write(Data("Cannot read request file.\n".utf8)); exit(2)
                }
                data = contents
            } else {
                guard let line = readLine() else { break }
                data = Data(line.utf8)
            }
            do {
                let request = try JSONDecoder().decode(ClefRequest.self, from: data)
                let limits = try JSONDecoder().decode(Limits.self, from: data)
                let questions = try request.resolvedQuestions()
                let loadStart = ContinuousClock.now
                if model == nil { model = try Clef.load(from: directory) }
                let loadSeconds = seconds(since: loadStart)
                let start = ContinuousClock.now
                let result = try model!.decide(state: request.state, questions: questions,
                                               maxTokens: limits.max_tokens ?? 4096)
                let elapsed = seconds(since: start)
                let fields: [[String: Any]] = result.decisions.map { decision in
                    var row: [String: Any] = ["id": decision.id, "probabilities": decision.probabilities,
                        "selected_option": decision.selectedOption, "confidence": decision.confidence]
                    if let score = decision.score { row["score"] = score }
                    if let noul = decision.noul { row["noul"] = noul }
                    return row
                }
                try emit(["backend": "mlx-metal", "decisions": fields, "input_tokens": result.inputTokens,
                          "load_seconds": loadSeconds, "decision_seconds": elapsed])
            } catch {
                // A rejected request does not discard the loaded model.
                do { try emit(["error": error.localizedDescription]) }
                catch { exit(1) }
                if CommandLine.arguments.count == 3 { exit(1) }
            }
        }
    }

    private struct Limits: Decodable { let max_tokens: Int? }
    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
    private static func emit(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
