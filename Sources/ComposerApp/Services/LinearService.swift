import Foundation

/// Talks to the Linear GraphQL API for the `@linear` connector using the user's personal API key
/// (stored via ConnectorSecretStore). Note Linear's auth quirk: a personal API key goes in the
/// `Authorization` header **raw**, with no `Bearer` prefix (only OAuth tokens use `Bearer`).
/// Search uses `issueSearch(query:)`; render fetches one issue by its UUID via `issue(id:)`.
struct LinearService {
  private let endpoint = URL(string: "https://api.linear.app/graphql")!

  func search(_ query: String) async throws -> [AppSearchResult] {
    let trimmed = query.trimmed
    guard !trimmed.isEmpty else { return [] }
    guard let key = ConnectorSecretStore.token(for: "@linear") else {
      throw AppSearchError.message("Add a Linear API key in Settings → Connectors → Linear.")
    }
    let gql = """
    query Search($q: String!) {
      issueSearch(query: $q, first: 8) {
        nodes { id identifier title state { name } assignee { name } }
      }
    }
    """
    let data: SearchData = try await post(gql, variables: ["q": trimmed], key: key)
    return data.issueSearch.nodes.map { node in
      let meta = [node.state?.name, node.assignee.map { "@\($0.name)" }].compactMap { $0 }.joined(separator: " · ")
      return AppSearchResult(
        id: node.id,
        title: "\(node.identifier)  \(node.title)",
        subtitle: meta,
        selection: .linear(LinearReference(id: node.id, identifier: node.identifier)))
    }
  }

  func render(_ reference: LinearReference) async -> String {
    let header = "## Linear — \(reference.identifier)"
    guard let key = ConnectorSecretStore.token(for: "@linear") else {
      return "\(header)\nAdd a Linear API key in Settings → Connectors → Linear."
    }
    let gql = """
    query Issue($id: String!) {
      issue(id: $id) {
        identifier title url priority description
        state { name }
        assignee { name }
        team { key name }
        project { name }
        labels { nodes { name } }
        comments(first: 10) { nodes { body user { name } } }
        attachments(first: 10) { nodes { title url } }
      }
    }
    """
    do {
      let data: IssueData = try await post(gql, variables: ["id": reference.id], key: key)
      guard let issue = data.issue else { return "\(header)\nIssue not found." }
      return format(issue)
    } catch let error as AppSearchError {
      return "\(header)\n\(error.errorDescription ?? "Could not load the Linear issue.")"
    } catch {
      return "\(header)\nCould not load the Linear issue: \(error.localizedDescription)"
    }
  }

  // MARK: - Rendering

  private func format(_ issue: Issue) -> String {
    var lines = ["## Linear — \(issue.identifier)" + (issue.title.isEmpty ? "" : "  \(issue.title)")]
    var meta: [String] = []
    if let state = issue.state?.name { meta.append("State: \(state)") }
    if let priority = priorityLabel(issue.priority) { meta.append("Priority: \(priority)") }
    if let team = issue.team { meta.append("Team: \(team.key)") }
    if let project = issue.project?.name { meta.append("Project: \(project)") }
    if let assignee = issue.assignee?.name { meta.append("Assignee: \(assignee)") }
    if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }
    if let labels = issue.labels?.nodes, !labels.isEmpty {
      lines.append("Labels: " + labels.map(\.name).joined(separator: ", "))
    }
    if let url = issue.url { lines.append("URL: \(url)") }
    lines.append("")
    let description = (issue.description ?? "").trimmed
    lines.append(description.isEmpty ? "_(no description)_" : description)
    if let comments = issue.comments?.nodes, !comments.isEmpty {
      lines.append("")
      lines.append("### Comments")
      for comment in comments.prefix(10) {
        let who = comment.user?.name ?? "someone"
        let body = comment.body.trimmed
        if !body.isEmpty { lines.append("- **@\(who)**: \(body)") }
      }
    }
    if let attachments = issue.attachments?.nodes, !attachments.isEmpty {
      lines.append("")
      lines.append("### Links")
      for attachment in attachments.prefix(10) {
        lines.append("- \(attachment.title ?? attachment.url): \(attachment.url)")
      }
    }
    return lines.joined(separator: "\n")
  }

  /// Linear priority: 0 none, 1 urgent, 2 high, 3 medium, 4 low.
  private func priorityLabel(_ value: Int?) -> String? {
    switch value {
    case 1: return "Urgent"
    case 2: return "High"
    case 3: return "Medium"
    case 4: return "Low"
    default: return nil
    }
  }

  // MARK: - Networking

  private func post<T: Decodable>(_ query: String, variables: [String: String], key: String) async throws -> T {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(key, forHTTPHeaderField: "Authorization")   // raw key — NOT "Bearer …"
    request.timeoutInterval = 12
    request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw AppSearchError.message("No response from Linear.") }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401 || http.statusCode == 403 {
        throw AppSearchError.message("Linear rejected the API key (\(http.statusCode)). Check Settings → Connectors → Linear.")
      }
      throw AppSearchError.message("Linear API error (\(http.statusCode)).")
    }
    let envelope = try JSONDecoder().decode(GraphQLResponse<T>.self, from: data)
    if let message = envelope.errors?.first?.message { throw AppSearchError.message("Linear: \(message)") }
    guard let payload = envelope.data else { throw AppSearchError.message("Linear returned no data.") }
    return payload
  }
}

// MARK: - Wire format

private struct GraphQLResponse<T: Decodable>: Decodable {
  let data: T?
  let errors: [GraphQLError]?
  struct GraphQLError: Decodable { let message: String }
}

private struct SearchData: Decodable {
  let issueSearch: Connection
  struct Connection: Decodable { let nodes: [Node] }
  struct Node: Decodable {
    let id: String
    let identifier: String
    let title: String
    let state: Named?
    let assignee: Named?
  }
}

private struct IssueData: Decodable { let issue: Issue? }

private struct Issue: Decodable {
  let identifier: String
  let title: String
  let url: String?
  let priority: Int?
  let description: String?
  let state: Named?
  let assignee: Named?
  let team: Team?
  let project: Named?
  let labels: NodeList<Named>?
  let comments: NodeList<Comment>?
  let attachments: NodeList<Attachment>?

  struct Team: Decodable { let key: String; let name: String? }
  struct Comment: Decodable { let body: String; let user: Named? }
  struct Attachment: Decodable { let title: String?; let url: String }
}

private struct Named: Decodable { let name: String }
private struct NodeList<Element: Decodable>: Decodable { let nodes: [Element] }
