import Foundation

/// Finds sign-in and verification codes in a message.
public enum OneTimeCode {
    private static let keyword = try! NSRegularExpression(pattern: """
        (verification|verify|confirmation|confirm|security|sign[- ]?in|log[- ]?in|login|one[- ]time|single[- ]use|\
        authenticat\\w*|access|passcode|2fa|two[- ]factor|mfa|otp|pin\\b|code|bestätigungscode|sicherheitscode|\
        código|codigo|verificación|vérification|codice|verificatiecode|код|コード|验证码)
        """, options: .caseInsensitive)

    private static let candidate = try! NSRegularExpression(pattern: """
        (?<![\\w$€£¥#/.,:-])(\\d{3}[- ]\\d{3}|\\d{4,8}|(?=[A-Z0-9]*[0-9])(?=[A-Z0-9]*[A-Z])[A-Z0-9]{6,8})(?![\\w/%:-]|[.,]\\w)
        """)

    private static let negative = try! NSRegularExpression(pattern: """
        (order|invoice|receipt|tracking|shipment|parcel|booking|reservation|ticket|case|account|acct|customer|member|\
        reference|ref|transaction|sku|item|model|serial|flight|room|phone|tel|fax|call|mobile|zip|postal|postcode|\
        amount|amt|total|price|balance|bal|usd|eur|gbp|inr|rs|₹|a/c|card|bestellung|rechnung|commande|facture|pedido|factura|ordine|\
        no\\.|nr\\.)\\W{0,3}$
        """, options: .caseInsensitive)

    /// Sender prefixes glued to the code, e.g. Google's "G-123456".
    private static let gluedPrefix = try! NSRegularExpression(pattern: "\\b[A-Z]{1,3}-(\\d{4,8})\\b")

    public static func detect(subject: String, body: String) -> String? {
        let subject = unglue(subject)
        if let c = find(in: subject, requireKeyword: true) { return c }
        let head = unglue(String(body.prefix(2500)))
        let hasKeyword = keyword.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
        return find(in: head, requireKeyword: !hasKeyword, keywordWindow: hasKeyword ? 2500 : 160)
    }

    static func unglue(_ s: String) -> String {
        gluedPrefix.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
    }

    static func find(in text: String, requireKeyword: Bool, keywordWindow: Int = 160) -> String? {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let keywords = keyword.matches(in: text, range: full).map(\.range)
        if requireKeyword && keywords.isEmpty { return nil }

        var best: (code: String, distance: Int)?
        for m in candidate.matches(in: text, range: full) {
            let raw = ns.substring(with: m.range)
            let code = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            if code.count == 4, let n = Int(code), (1900...2099).contains(n) { continue }
            if code.allSatisfy(\.isNumber), Set(code).count == 1 { continue }
            // Masked card or account numbers: "XX1234", "XXXX5678".
            if code.range(of: "^[Xx*]{2,}\\d+$", options: .regularExpression) != nil { continue }

            let beforeStart = max(0, m.range.location - 24)
            let before = ns.substring(with: NSRange(location: beforeStart, length: m.range.location - beforeStart))
            if negative.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) != nil { continue }
            if before.hasSuffix("+") || before.hasSuffix("(") { continue }
            // "#4821" or "# 4821" is a reference number ("<#>" is Android's SMS-autofill tag, not this).
            if before.hasSuffix("#") || (before.hasSuffix("# ") && !before.hasSuffix("<#> ")) { continue }

            let distance: Int
            if keywords.isEmpty {
                distance = keywordWindow
            } else {
                distance = keywords.map { k in
                    if k.location > m.range.location { return k.location - (m.range.location + m.range.length) }
                    return m.range.location - (k.location + k.length)
                }.map { max(0, $0) }.min() ?? Int.max
            }
            guard distance <= keywordWindow else { continue }
            if best == nil || distance < best!.distance { best = (code, distance) }
        }
        return best?.code
    }
}
