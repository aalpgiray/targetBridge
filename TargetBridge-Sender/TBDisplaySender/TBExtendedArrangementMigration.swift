import Foundation

enum TBExtendedArrangementMigration {
    static func key(prefix: String, identity: String, width: Int, height: Int) -> String {
        let normalized = identity.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression
        )
        return "\(prefix).\(normalized).\(width)x\(height)"
    }

    static func load(
        defaults: UserDefaults, prefix: String, identity: String,
        legacyIdentities: [String], width: Int, height: Int
    ) -> [String: Any]? {
        let currentKey = key(prefix: prefix, identity: identity, width: width, height: height)
        if let existing = defaults.dictionary(forKey: currentKey) { return existing }
        for alias in legacyIdentities {
            let oldKey = key(prefix: prefix, identity: alias, width: width, height: height)
            guard let stored = defaults.dictionary(forKey: oldKey),
                  (stored["dx"] is Int && stored["dy"] is Int) ||
                    (stored["x"] is Int && stored["y"] is Int) else { continue }
            defaults.set(stored, forKey: currentKey)
            return stored
        }
        return nil
    }
}
