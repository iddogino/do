import Foundation

/// When Do asks before running a model-proposed shell command.
///
/// Mage-VL-Cowork was trained in disposable VMs; Do runs it on a real Mac. The model card asks
/// deployers to require human confirmation before irreversible actions, so by default commands
/// that look destructive, privileged, or remote-code-executing are held for approval.
public enum CommandApprovalMode: String, CaseIterable, Sendable, Codable {
    case always
    case risky
    case never
}

public enum CommandSafety {

    public struct Assessment: Equatable, Sendable {
        public var isRisky: Bool
        public var reasons: [String]
    }

    private static let patterns: [(String, String)] = [
        (#"(^|[\s;&|(])sudo\b"#, "runs with administrator privileges"),
        (#"(^|[\s;&|(])(doas|su)\s"#, "switches user"),
        (#"\brm\s+(-[a-zA-Z]*[rRf][a-zA-Z]*\s+)+"#, "recursively or forcibly deletes files"),
        (#"\brm\s+[^|;&]*(\s|^)(~|/|\$HOME)(/|\s|$)"#, "deletes from a top-level location"),
        (#"\b(rmdir|unlink|shred|srm)\b"#, "deletes files"),
        (#"\bfind\b[^|;&]*\s-(delete|exec\s+rm)\b"#, "deletes files found by find"),
        (#"\bgit\s+(push|reset\s+--hard|clean\s+-[a-zA-Z]*f|checkout\s+--\s|branch\s+-D|filter-branch)"#, "rewrites or publishes git history"),
        (#"\b(diskutil|newfs_\w+|fdisk|gpt|asr|bless|nvram|csrutil|spctl|tmutil\s+(delete|disable))\b"#, "changes disks or system security"),
        (#"\bdd\s+[^|;&]*\bof="#, "writes raw data to a file or device"),
        (#"\b(mkfs|format)\b"#, "formats storage"),
        (#"\b(shutdown|reboot|halt)\b|\bpmset\b"#, "affects power state"),
        (#"\blaunchctl\s+(load|bootstrap|enable|submit)|\bcrontab\b|LaunchAgents|LaunchDaemons"#, "installs background jobs"),
        (#"\b(curl|wget)\b[^|;]*\|\s*(sudo\s+)?(ba|z|fi|k)?sh\b"#, "downloads and executes a script"),
        (#"\b(bash|zsh|sh)\s+<\s*\(\s*(curl|wget)"#, "downloads and executes a script"),
        (#"\b(curl|wget|scp|rsync|ftp|sftp|nc|ncat)\b[^|;&]*(-T|--upload-file|-F|--data|-d\s|@|PUT|POST)"#, "uploads data"),
        (#"\bssh\s"#, "connects to another machine"),
        (#"\b(security)\s+(find|dump|delete|export)"#, "accesses the keychain"),
        (#"\bchmod\s+(-R\s+)?[0-7]*7[0-7]*\s+/|\bchown\s+-R\b"#, "changes permissions broadly"),
        (#"\bdefaults\s+delete\b"#, "deletes preferences"),
        (#"\bkillall\b|\bpkill\b|\bkill\s+-9\b"#, "terminates processes"),
        (#"\b(brew|pip3?|npm|gem|cargo)\s+(install|uninstall|remove)\b"#, "installs or removes software"),
        (#"\bosascript\b[^|;&]*(do shell script|keystroke|System Events)"#, "scripts other apps or the system"),
        (#"(^|\s)>\s*/(etc|System|Library|usr|bin|sbin)/"#, "writes to a system location"),
        (#"\b(mv|cp)\b[^|;&]*\s/(etc|System|Library|usr|bin|sbin)/"#, "writes to a system location"),
        (#":\(\)\s*\{"#, "fork bomb"),
    ]

    private static let compiled: [(NSRegularExpression, String)] = patterns.compactMap { pattern, reason in
        (try? NSRegularExpression(pattern: pattern, options: [])).map { ($0, reason) }
    }

    public static func assess(_ command: String) -> Assessment {
        let range = NSRange(command.startIndex ..< command.endIndex, in: command)
        var reasons: [String] = []
        for (regex, reason) in compiled where regex.firstMatch(in: command, range: range) != nil {
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        return Assessment(isRisky: !reasons.isEmpty, reasons: reasons)
    }

    public static func requiresApproval(_ command: String, mode: CommandApprovalMode) -> Bool {
        switch mode {
        case .always: true
        case .never: false
        case .risky: assess(command).isRisky
        }
    }
}
