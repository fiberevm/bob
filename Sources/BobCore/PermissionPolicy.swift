import Foundation

public enum ToolEffect { case read, write, shell, browserInteraction, computerInteraction }

public struct PermissionPolicy {
    public init() {}
    public func requiresApproval(_ effect: ToolEffect, assessment: ToolSafetyAssessment? = nil) -> Bool {
        if let assessment, !assessment.risk.requiresConfirmation, assessment.outcome == .allow { return false }
        switch effect { case .read: return false; case .write, .shell, .browserInteraction, .computerInteraction: return true }
    }
    public func shellEnvironment(inherited: [String: String] = ExecutableLocator.environment) -> [String: String] {
        // Never inherit provider keys, shell startup hooks, proxies, or arbitrary app secrets.
        var result = ["PATH": inherited["PATH"] ?? ExecutableLocator.environment["PATH"]!,
                      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                      "TMPDIR": FileManager.default.temporaryDirectory.path,
                      "USER": NSUserName(), "LOGNAME": NSUserName(), "TERM": "dumb"]
        for key in ["LANG", "LC_ALL", "LC_CTYPE", "TZ"] { if let value = inherited[key] { result[key] = value } }
        return result
    }
}
