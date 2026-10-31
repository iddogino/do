import Testing

@testable import DoCore

@Suite("ResponseParser")
struct ResponseParserTests {

    @Test func parsesComputerTurn() {
        let response = """
            The Appearance pane is open and Light is selected. Dark is on the right.
            </think>

            Action: Click the Dark appearance tile.

            <tool_call>
            {"name": "computer_use", "arguments": {"action": "click", "coordinate": [711, 264]}}
            </tool_call>
            """
        let turn = ResponseParser.parse(response)
        #expect(turn.thinking.hasPrefix("The Appearance pane is open"))
        #expect(turn.actionSentence == "Click the Dark appearance tile.")
        #expect(turn.invocation == .computer([.click(NormalizedPoint(x: 711, y: 264), button: .left)]))
        #expect(turn.issues.isEmpty)
    }

    @Test func parsesMultipleCallsAndAllActionKinds() {
        let response = """
            <think>x</think>
            Action: Do several things.
            <tool_call>{"name": "computer_use", "arguments": {"action": "double_click", "coordinate": [1, 2]}}</tool_call>
            <tool_call>{"name": "computer_use", "arguments": {"action": "triple_click", "coordinate": ["3", "4"]}}</tool_call>
            <tool_call>{"name": "computer_use", "arguments": {"action": "click", "coordinate": [5, 6], "button": "right"}}</tool_call>
            <tool_call>{"name": "computer_use", "arguments": {"action": "drag", "start": [10, 10], "end": [20, 30]}}</tool_call>
            <tool_call>{"name": "computer_use", "arguments": {"action": "type", "text": "hello\\nworld"}}</tool_call>
            <tool_call>{"name": "computer_use", "arguments": {"action": "keypress", "keys": ["ctrl", "s"]}}</tool_call>
            <tool_call>{"name": "computer_use", "arguments": {"action": "keypress", "keys": "cmd+shift+t"}}</tool_call>
            <tool_call>{"name": "computer_use", "arguments": {"action": "scroll", "coordinate": [500, 500], "scroll_y": -400}}</tool_call>
            <tool_call>{"name": "computer_use", "arguments": {"action": "wait", "time": 2}}</tool_call>
            <tool_call>{"name": "computer_use", "arguments": {"action": "move", "coordinate": [100, 900]}}</tool_call>
            """
        let turn = ResponseParser.parse(response)
        guard case .computer(let actions) = turn.invocation else {
            Issue.record("expected computer invocation")
            return
        }
        #expect(
            actions == [
                .doubleClick(NormalizedPoint(x: 1, y: 2)),
                .tripleClick(NormalizedPoint(x: 3, y: 4)),
                .click(NormalizedPoint(x: 5, y: 6), button: .right),
                .drag(from: NormalizedPoint(x: 10, y: 10), to: NormalizedPoint(x: 20, y: 30)),
                .type("hello\nworld"),
                .keypress(["ctrl", "s"]),
                .keypress(["cmd", "shift", "t"]),
                .scroll(at: NormalizedPoint(x: 500, y: 500), dx: 0, dy: -400),
                .wait(seconds: 2),
                .move(NormalizedPoint(x: 100, y: 900)),
            ])
    }

    @Test func parsesBashTurn() {
        let response = """
            Use the shell.
            </think>

            Action: List the Desktop.

            <tool_call>
            {"name": "bash", "arguments": {"command": "ls -la ~/Desktop"}}
            </tool_call>
            """
        let turn = ResponseParser.parse(response)
        #expect(turn.invocation == .bash(["ls -la ~/Desktop"]))
        #expect(turn.actionSentence == "List the Desktop.")
    }

    @Test func rejectsMixedToolFamilies() {
        let response = """
            Action: Mixed.
            <tool_call>{"name": "bash", "arguments": {"command": "ls"}}</tool_call>
            <tool_call>{"name": "computer_use", "arguments": {"action": "click", "coordinate": [1, 1]}}</tool_call>
            """
        let turn = ResponseParser.parse(response)
        #expect(turn.invocation == nil)
        #expect(!turn.issues.isEmpty)
    }

    @Test func terminateWithMessage() {
        let response = """
            Done.</think>
            Action: Finish the task.
            <tool_call>
            {"name": "computer_use", "arguments": {"action": "terminate", "status": "success", "msg_to_user": "Dark mode is on."}}
            </tool_call>
            """
        let turn = ResponseParser.parse(response)
        #expect(turn.invocation == .computer([.terminate(success: true, message: "Dark mode is on.")]))
        #expect(turn.isTerminal)
    }

    @Test func toleratesTrailingJunkAndUnterminatedBlock() {
        let junk = """
            Action: Click.
            <tool_call>
            {"name": "computer_use", "arguments": {"action": "click", "coordinate": [1, 2]}} extra
            </tool_call>
            """
        #expect(ResponseParser.parse(junk).invocation == .computer([.click(NormalizedPoint(x: 1, y: 2), button: .left)]))

        let truncated = """
            Action: Click.
            <tool_call>
            {"name": "computer_use", "arguments": {"action": "click", "coordinate": [7, 8]}}
            """
        #expect(ResponseParser.parse(truncated).invocation == .computer([.click(NormalizedPoint(x: 7, y: 8), button: .left)]))
    }

    @Test func fallsBackToBareJSONLines() {
        let response = """
            Action: Press enter.
            {"name": "computer_use", "arguments": {"action": "keypress", "keys": ["enter"]}}
            """
        #expect(ResponseParser.parse(response).invocation == .computer([.keypress(["enter"])]))
    }

    @Test func synthesizesSummaryWhenActionLineMissing() {
        let response = #"<tool_call>{"name": "computer_use", "arguments": {"action": "type", "text": "hi"}}</tool_call>"#
        #expect(ResponseParser.parse(response).actionSentence == "Type the requested text.")
    }

    @Test func clampsCoordinates() {
        let response = #"<tool_call>{"name": "computer_use", "arguments": {"action": "click", "coordinate": [1200, -5]}}</tool_call>"#
        #expect(ResponseParser.parse(response).invocation == .computer([.click(NormalizedPoint(x: 999, y: 0), button: .left)]))
    }

    @Test func capsToolCallsAtFifteen() {
        let one = #"<tool_call>{"name": "bash", "arguments": {"command": "true"}}</tool_call>"#
        let turn = ResponseParser.parse(String(repeating: one + "\n", count: 20))
        guard case .bash(let commands) = turn.invocation else {
            Issue.record("expected bash")
            return
        }
        #expect(commands.count == 15)
    }
}
