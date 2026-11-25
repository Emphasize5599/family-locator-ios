import Foundation

/// One issued invite link. `usedBy` is the account that redeemed it; nil means it is still unused.
nonisolated struct InviteRecord: Codable, Equatable, Sendable {
    var token: Data
    var usedBy: Data?
}

/// One-time invite tokens. The server never sees them in the clear: each client stores the tokens it issued,
/// and a link works only when the inviter still has that exact token unused.
nonisolated enum InviteLedger {
    static let tokenLength = 16
    /// Keep recent redemptions as well as unused links when trimming the backup.
    static let cap = 40

    static func issued(_ token: Data, into records: [InviteRecord]) -> [InviteRecord] {
        trim(records + [InviteRecord(token: token)])
    }

    /// Consumes an unused token for the sender. Replays and unrecognized tokens are rejected.
    static func authorize(_ token: Data, sender: Data, records: inout [InviteRecord]) -> Bool {
        guard token.count == tokenLength, sender.count == tokenLength,
              let index = records.firstIndex(where: { $0.token == token }) else { return false }
        guard records[index].usedBy == nil else { return false }
        records[index].usedBy = sender
        return true
    }

    /// A token is used if either side says so. Local wins when the two sides name different people.
    static func merge(local: [InviteRecord], remote: [InviteRecord]) -> [InviteRecord] {
        var ordered: [InviteRecord] = []
        func add(_ record: InviteRecord) {
            guard record.token.count == tokenLength else { return }
            let usedBy = record.usedBy?.count == tokenLength ? record.usedBy : nil
            if let index = ordered.firstIndex(where: { $0.token == record.token }) {
                if ordered[index].usedBy == nil { ordered[index].usedBy = usedBy }
            } else {
                ordered.append(InviteRecord(token: record.token, usedBy: usedBy))
            }
        }
        local.forEach(add)
        remote.forEach(add)
        return trim(ordered)
    }

    static func trim(_ records: [InviteRecord]) -> [InviteRecord] {
        guard records.count > cap else { return records }
        let unused = records.indices.filter { records[$0].usedBy == nil }
        let used = records.indices.filter { records[$0].usedBy != nil }
        let usedTarget = min(used.count, cap / 2)
        let unusedTarget = min(unused.count, cap - usedTarget)
        let usedFinal = min(used.count, cap - unusedTarget)
        let keep = Set(unused.suffix(unusedTarget)).union(used.suffix(usedFinal))
        return records.indices.filter { keep.contains($0) }.map { records[$0] }
    }

    /// Base64url without padding, the form that goes in a link's `t` parameter.
    static func queryToken(_ token: Data) -> String? {
        guard token.count == tokenLength else { return nil }
        return token.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes a link token. Invalid or wrong-length values are nil so the link falls back to a normal request.
    static func token(fromQuery raw: String) -> Data? {
        var base64 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64), data.count == tokenLength else { return nil }
        return data
    }
}
