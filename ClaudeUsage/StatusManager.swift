import Foundation

struct ComponentDisruption {
    let name: String
    let status: String
}

@MainActor
class StatusManager: ObservableObject {
    @Published var disruptions: [ComponentDisruption] = []

    private static let trackedComponentIDs: Set<String> = [
        "0qbwn08sd68x", // claude.ai
        "k8w3r06qmzrp", // Claude API
        "yyzkbfz2thpt", // Claude Code
    ]

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    var badgeEmoji: String? {
        guard !disruptions.isEmpty else { return nil }
        let hasOutage = disruptions.contains { disruption in
            disruption.status == "major_outage" || disruption.status == "partial_outage"
        }
        return hasOutage ? "🔥" : "⚠️"
    }

    func refresh() async {
        guard let url = URL(string: "https://status.claude.com/api/v2/components.json") else { return }

        do {
            let (data, _) = try await urlSession.data(from: url)

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let components = json["components"] as? [[String: Any]] else {
                return
            }

            disruptions = components.compactMap { component in
                guard let id = component["id"] as? String,
                      let name = component["name"] as? String,
                      let status = component["status"] as? String,
                      Self.trackedComponentIDs.contains(id),
                      status != "operational" else {
                    return nil
                }
                return ComponentDisruption(name: name, status: status)
            }.sorted { $0.name < $1.name }
        } catch {
            // Silent failure — leave disruptions unchanged
        }
    }
}
