import Foundation

/// Parses Mage-VL-Cowork's three-part turn format:
///
///     <think>…</think>
///
///     Action: one short imperative sentence.
///
///     <tool_call>
///     {"name": "computer_use", "arguments": {...}}
///     </tool_call>
///
/// Mirrors the reference harness (`_extract_hybrid_tool_calls`, `_parse_computer_response`),
/// including its fallbacks for slightly malformed output.
public enum ResponseParser {
    public static let maxToolCalls = 15

    public static func parse(_ response: String) -> AgentTurn {
        var issues: [String] = []
        let thinking = extractThinking(response)
        var sentence = extractActionSentence(response)

        let calls = extractToolCalls(response, issues: &issues)
        var invocation: ToolInvocation?

        if calls.isEmpty {
            issues.append("no tool_call found")
        } else {
            var limited = calls
            if limited.count > maxToolCalls {
                issues.append("truncated \(calls.count) tool calls to \(maxToolCalls)")
                limited = Array(limited.prefix(maxToolCalls))
            }
            let names = Set(limited.map { ($0["name"] as? String) ?? "" })
            if names.count != 1 || !names.isSubset(of: ["computer_use", "bash"]) {
                issues.append("one tool family per response required; got \(names.sorted())")
            } else if names.first == "bash" {
                let commands = limited.compactMap { call -> String? in
                    let args = call["arguments"] as? [String: Any]
                    guard let command = args?["command"] as? String, !command.isEmpty else {
                        issues.append("bash call without command")
                        return nil
                    }
                    return command
                }
                if !commands.isEmpty { invocation = .bash(commands) }
            } else {
                let actions = limited.compactMap { call -> ComputerAction? in
                    let args = (call["arguments"] as? [String: Any]) ?? [:]
                    do {
                        return try computerAction(from: args)
                    } catch {
                        issues.append("\(error)")
                        return nil
                    }
                }
                if !actions.isEmpty { invocation = .computer(actions) }
            }
        }

        if sentence.isEmpty {
            sentence = summarize(invocation)
        }
        return AgentTurn(
            raw: response, thinking: thinking, actionSentence: sentence, invocation: invocation, issues: issues)
    }

    // MARK: Pieces

    /// The generation prompt already opens `<think>`, so the response usually starts inside it.
    static func extractThinking(_ response: String) -> String {
        guard let close = response.range(of: "</think>") else { return "" }
        var head = String(response[..<close.lowerBound])
        if let open = head.range(of: "<think>", options: .backwards) {
            head = String(head[open.upperBound...])
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `(?im)^\s*Action\s*:\s*(.+?)\s*$`
    static func extractActionSentence(_ response: String) -> String {
        let afterThink = response.range(of: "</think>").map { String(response[$0.upperBound...]) } ?? response
        for source in [afterThink, response] {
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.lowercased().hasPrefix("action") else { continue }
                let rest = trimmed.dropFirst("action".count).drop { $0 == " " || $0 == "\t" }
                guard rest.first == ":" else { continue }
                let value = rest.dropFirst().trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return value }
            }
        }
        return ""
    }

    static func extractToolCalls(_ response: String, issues: inout [String]) -> [[String: Any]] {
        var calls: [[String: Any]] = []
        var searchRange = response.startIndex ..< response.endIndex
        while let open = response.range(of: "<tool_call>", range: searchRange) {
            guard let close = response.range(of: "</tool_call>", range: open.upperBound ..< response.endIndex) else {
                // Truncated final block (e.g. ran out of tokens): try to salvage it.
                let body = String(response[open.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let obj = decodeObject(body) { calls.append(obj) } else { issues.append("unterminated tool_call") }
                break
            }
            let body = String(response[open.upperBound ..< close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let obj = decodeObject(body) {
                calls.append(obj)
            } else {
                issues.append("invalid tool_call JSON: \(body.prefix(200))")
            }
            searchRange = close.upperBound ..< response.endIndex
        }
        if calls.isEmpty {
            // Fallback: bare JSON objects on their own lines.
            for line in response.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("{"), t.hasSuffix("}"), let obj = decodeObject(t) else { continue }
                if let name = obj["name"] as? String, name == "computer_use" || name == "bash" {
                    calls.append(obj)
                }
            }
        }
        return calls
    }

    static func decodeObject(_ text: String) -> [String: Any]? {
        if let obj = jsonObject(text) { return obj }
        // Tolerate trailing junk after a balanced object.
        if let end = balancedObjectEnd(text), let obj = jsonObject(String(text[...end])) { return obj }
        return nil
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return obj as? [String: Any]
    }

    private static func balancedObjectEnd(_ text: String) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        for i in text.indices {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
        }
        return nil
    }

    // MARK: computer_use arguments

    public struct ArgumentError: Error, CustomStringConvertible {
        public let description: String
    }

    static func computerAction(from args: [String: Any]) throws -> ComputerAction {
        let action = ((args["action"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        func point(_ key: String) throws -> NormalizedPoint {
            guard let p = normalizedPoint(args[key]) else {
                throw ArgumentError(description: "\(action): missing or invalid \(key)")
            }
            return p
        }
        switch action {
        case "click":
            let button = MouseButton(rawValue: ((args["button"] as? String) ?? "left").lowercased()) ?? .left
            return .click(try point("coordinate"), button: button)
        case "double_click":
            return .doubleClick(try point("coordinate"))
        case "triple_click":
            return .tripleClick(try point("coordinate"))
        case "move":
            return .move(try point("coordinate"))
        case "drag":
            return .drag(from: try point("start"), to: try point("end"))
        case "type":
            return .type(stringValue(args["text"]) ?? "")
        case "keypress":
            let keys = keyList(args["keys"] ?? args["key"])
            guard !keys.isEmpty else { throw ArgumentError(description: "keypress: no keys") }
            return .keypress(keys)
        case "scroll":
            let dy = number(args["scroll_y"]) ?? 0
            let dx = number(args["scroll_x"]) ?? 0
            guard dx != 0 || dy != 0 else { throw ArgumentError(description: "scroll: zero amount") }
            return .scroll(
                at: normalizedPoint(args["coordinate"]),
                dx: min(max(dx, -999), 999), dy: min(max(dy, -999), 999))
        case "wait":
            return .wait(seconds: min(max(number(args["time"]) ?? 1, 0.1), 60))
        case "screenshot":
            return .screenshot
        case "terminate":
            let status = ((args["status"] as? String) ?? "success").lowercased()
            return .terminate(success: status != "failure", message: stringValue(args["msg_to_user"]))
        default:
            throw ArgumentError(description: "unsupported action \"\(action)\"")
        }
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    static func normalizedPoint(_ value: Any?) -> NormalizedPoint? {
        var parts: [Any] = []
        if let array = value as? [Any] {
            parts = array
        } else if let s = value as? String {
            // "(x, y)" / "[x, y]" / "x,y"
            let cleaned = s.trimmingCharacters(in: CharacterSet(charactersIn: "()[] "))
            parts = cleaned.split(separator: ",").map { String($0) }
        }
        guard parts.count == 2, let x = number(parts[0]), let y = number(parts[1]) else { return nil }
        return NormalizedPoint(x: x, y: y)
    }

    static func keyList(_ value: Any?) -> [String] {
        if let array = value as? [Any] {
            return array.compactMap { stringValue($0)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let s = stringValue(value)?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            return s.count > 1 && s.contains("+")
                ? s.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : [s]
        }
        return []
    }

    static func summarize(_ invocation: ToolInvocation?) -> String {
        switch invocation {
        case nil: "No executable action"
        case .bash: "Run the requested shell command."
        case .computer(let actions):
            switch actions.first {
            case .click, .doubleClick, .tripleClick: "Click the target element."
            case .type: "Type the requested text."
            case .keypress: "Press the requested key(s)."
            case .scroll: "Scroll the page."
            case .drag: "Drag between the selected points."
            case .terminate(let ok, _): ok ? "DONE" : "FAIL"
            default: "Execute the next GUI action."
            }
        }
    }
}
