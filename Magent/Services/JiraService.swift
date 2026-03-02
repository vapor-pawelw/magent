import Foundation

// MARK: - Types

nonisolated struct JiraAuthStatus: Sendable {
    let isAuthenticated: Bool
    let siteURL: String?
    let email: String?
    let errorMessage: String?
}

nonisolated struct JiraBoard: Codable, Sendable {
    let id: Int
    let name: String
    let type: String?
}

nonisolated struct JiraTicket: Codable, Sendable {
    let key: String
    let summary: String
    let status: String
    let assigneeAccountId: String?
    let issueId: Int?
}

enum JiraError: LocalizedError {
    case acliNotInstalled
    case notAuthenticated
    case commandFailed(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .acliNotInstalled:
            return "acli CLI is not installed"
        case .notAuthenticated:
            return "Not authenticated with Jira"
        case .commandFailed(let message):
            return "Jira error: \(message)"
        case .parseError(let message):
            return "Failed to parse Jira response: \(message)"
        }
    }
}

// MARK: - Service

final class JiraService {

    static let shared = JiraService()

    // MARK: - CLI Check

    func isAcliInstalled() async -> Bool {
        let result = await ShellExecutor.execute("which acli")
        return result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Auth

    func checkAuthStatus() async -> JiraAuthStatus {
        let result = await ShellExecutor.execute("acli jira auth status")
        let output = result.stdout + result.stderr
        let lines = output.components(separatedBy: "\n")

        var isAuthenticated = false
        var siteURL: String?
        var email: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("Authenticated") || trimmed.contains("authenticated") {
                isAuthenticated = true
            }
            if let siteMatch = extractValue(from: trimmed, prefix: "Site:") ??
                extractValue(from: trimmed, prefix: "URL:") ??
                extractValue(from: trimmed, prefix: "Server:") {
                siteURL = siteMatch
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            if let emailMatch = extractValue(from: trimmed, prefix: "Email:") ??
                extractValue(from: trimmed, prefix: "User:") {
                email = emailMatch
            }
        }

        if result.exitCode != 0 && !isAuthenticated {
            return JiraAuthStatus(
                isAuthenticated: false,
                siteURL: nil,
                email: nil,
                errorMessage: output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return JiraAuthStatus(
            isAuthenticated: isAuthenticated,
            siteURL: siteURL,
            email: email,
            errorMessage: nil
        )
    }

    func openLoginPage() async {
        _ = await ShellExecutor.execute("acli jira auth login")
    }

    // MARK: - Boards

    func listBoards() async throws -> [JiraBoard] {
        try await ensureAuthenticated()

        let result = await ShellExecutor.execute("acli jira board search --json --paginate")
        guard result.exitCode == 0 else {
            throw JiraError.commandFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return try parseJSONArray(result.stdout)
    }

    // MARK: - Tickets

    func searchTickets(jql: String) async throws -> [JiraTicket] {
        try await ensureAuthenticated()

        let escapedJQL = shellQuote(jql)
        let result = await ShellExecutor.execute(
            "acli jira workitem search --jql \(escapedJQL) --json --fields \"key,status,summary,assignee\" --paginate"
        )
        guard result.exitCode == 0 else {
            let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if error.lowercased().contains("auth") || error.lowercased().contains("401") {
                throw JiraError.notAuthenticated
            }
            throw JiraError.commandFailed(error)
        }

        return try parseTickets(from: result.stdout)
    }

    // MARK: - Status Discovery

    func discoverStatuses(projectKey: String) async throws -> [String] {
        let jql = "project = \(projectKey) ORDER BY updated DESC"
        let tickets = try await searchTickets(jql: jql)

        var seen = Set<String>()
        var statuses: [String] = []
        for ticket in tickets {
            let status = ticket.status
            if !status.isEmpty && seen.insert(status).inserted {
                statuses.append(status)
            }
        }
        return statuses
    }

    // MARK: - URL Builders

    func boardURL(siteURL: String, projectKey: String, boardId: Int) -> URL? {
        let site = siteURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "https://\(site)/jira/software/projects/\(projectKey)/boards/\(boardId)")
    }

    func ticketURL(siteURL: String, ticketKey: String) -> URL? {
        let site = siteURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "https://\(site)/browse/\(ticketKey)")
    }

    func projectURL(siteURL: String, projectKey: String) -> URL? {
        let site = siteURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "https://\(site)/jira/software/projects/\(projectKey)/board")
    }

    // MARK: - Private Helpers

    private func ensureAuthenticated() async throws {
        let status = await checkAuthStatus()
        if !status.isAuthenticated {
            throw JiraError.notAuthenticated
        }
    }

    private func extractValue(from line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func parseJSONArray<T: Decodable>(_ jsonString: String) throws -> [T] {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8) else {
            throw JiraError.parseError("Invalid UTF-8 data")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Try parsing as array first
        if let items = try? decoder.decode([T].self, from: data) {
            return items
        }

        // Try JSONL (one JSON object per line)
        var items: [T] = []
        for line in trimmed.components(separatedBy: "\n") {
            let lineTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineTrimmed.isEmpty, let lineData = lineTrimmed.data(using: .utf8) else { continue }
            if let item = try? decoder.decode(T.self, from: lineData) {
                items.append(item)
            }
        }

        if items.isEmpty && !trimmed.isEmpty {
            throw JiraError.parseError("Could not parse response")
        }

        return items
    }

    private func parseTickets(from jsonString: String) throws -> [JiraTicket] {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let data = trimmed.data(using: .utf8) else {
            throw JiraError.parseError("Invalid UTF-8 data")
        }

        // Try standard JSON array
        if let rawItems = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return rawItems.compactMap { parseTicketFromDict($0) }
        }

        // Try as single object
        if let rawItem = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let ticket = parseTicketFromDict(rawItem) {
                return [ticket]
            }
        }

        // Try JSONL
        var tickets: [JiraTicket] = []
        for line in trimmed.components(separatedBy: "\n") {
            let lineTrimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineTrimmed.isEmpty,
                  let lineData = lineTrimmed.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let ticket = parseTicketFromDict(dict) else { continue }
            tickets.append(ticket)
        }

        return tickets
    }

    private func parseTicketFromDict(_ dict: [String: Any]) -> JiraTicket? {
        guard let key = dict["key"] as? String else { return nil }

        let summary: String
        if let s = dict["summary"] as? String {
            summary = s
        } else if let fields = dict["fields"] as? [String: Any],
                  let s = fields["summary"] as? String {
            summary = s
        } else {
            summary = ""
        }

        let status: String
        if let s = dict["status"] as? String {
            status = s
        } else if let statusObj = dict["status"] as? [String: Any],
                  let name = statusObj["name"] as? String {
            status = name
        } else if let fields = dict["fields"] as? [String: Any] {
            if let s = fields["status"] as? String {
                status = s
            } else if let statusObj = fields["status"] as? [String: Any],
                      let name = statusObj["name"] as? String {
                status = name
            } else {
                status = ""
            }
        } else {
            status = ""
        }

        let assigneeAccountId: String?
        if let aId = dict["assigneeAccountId"] as? String {
            assigneeAccountId = aId
        } else if let assignee = dict["assignee"] as? [String: Any],
                  let aId = assignee["accountId"] as? String {
            assigneeAccountId = aId
        } else if let fields = dict["fields"] as? [String: Any],
                  let assignee = fields["assignee"] as? [String: Any],
                  let aId = assignee["accountId"] as? String {
            assigneeAccountId = aId
        } else {
            assigneeAccountId = nil
        }

        let issueId: Int?
        if let id = dict["id"] as? Int {
            issueId = id
        } else if let idStr = dict["id"] as? String, let id = Int(idStr) {
            issueId = id
        } else {
            issueId = nil
        }

        return JiraTicket(
            key: key,
            summary: summary,
            status: status,
            assigneeAccountId: assigneeAccountId,
            issueId: issueId
        )
    }

}
