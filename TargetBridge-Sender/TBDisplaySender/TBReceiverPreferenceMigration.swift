import Foundation

enum TBReceiverPreferenceMigration {
    static func codecKey(identity: String, receiverIP: String) -> String? {
        let identity = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if identity.hasPrefix("receiver:") || identity.hasPrefix("service:") {
            return identity
        }
        if let uuid = UUID(uuidString: identity) {
            return "receiver:\(uuid.uuidString)"
        }
        if let service = identity.split(separator: "|", maxSplits: 1).first {
            return "service:\(service)"
        }
        let ip = receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return ip.isEmpty ? nil : "ip:\(ip)"
    }

    static func migrateProfiles(
        _ values: inout [String: String], identity: String,
        matchesIdentity: (String) -> Bool
    ) {
        let aliases = values.keys.sorted().filter {
            $0.hasPrefix("id:") && matchesIdentity(String($0.dropFirst(3)))
        }
        copyIfMissing(to: "id:\(identity)", from: aliases, in: &values)
    }

    static func migrateCodecs(
        _ values: inout [String: String], identity: String,
        serviceName: String, matchesIdentity: (String) -> Bool
    ) {
        // The doubled prefix was emitted by the initial UUID-based save path.
        let preferredAliases = ["service:\(identity)", "service:\(serviceName)"]
        let otherAliases = values.keys.sorted().filter {
            matchesIdentity($0) ||
                ($0.hasPrefix("service:") && matchesIdentity(String($0.dropFirst(8))))
        }
        copyIfMissing(to: identity, from: preferredAliases + otherAliases, in: &values)
    }

    private static func copyIfMissing(
        to key: String, from aliases: [String], in values: inout [String: String]
    ) {
        guard values[key] == nil,
              let value = aliases.compactMap({ values[$0] }).first else { return }
        values[key] = value
    }
}
