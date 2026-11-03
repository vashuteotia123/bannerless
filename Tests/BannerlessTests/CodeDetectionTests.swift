import Foundation
import Testing
@testable import CodeCore

/// Finding the code in an email-style subject and body.
@Suite struct CodeDetectionTests {
    @Test(arguments: [
        ("482913 is your Northwind sign-in code", "", "482913"),
        ("Your verification code", "Hi Sam,\n\nUse 739 204 to finish signing in.\nIt expires in 10 minutes.", "739204"),
        ("Sign in to Linear", "Your login code is: K7Q2XP", "K7Q2XP"),
        ("Bestätigungscode", "Ihr Code lautet 5821.", "5821"),
    ])
    func findsCodes(subject: String, body: String, expected: String) {
        #expect(OneTimeCode.detect(subject: subject, body: body) == expected)
    }

    @Test(arguments: [
        ("Your order has shipped", "Order #123456 is on its way. Tracking number 9400111899223."),
        ("Invoice 2026-118", "Amount due: $1,250.00. Call 555-1234 with questions."),
        ("Lunch on Friday?", "Are you free at 1230? Room 4410."),
        ("Your code review", "Merged in 2026 by Ana."),
    ])
    func ignoresNonCodes(subject: String, body: String) {
        #expect(OneTimeCode.detect(subject: subject, body: body) == nil)
    }
}
