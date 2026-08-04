import Foundation

extension Interpreter {
    /// Apply Foundation's printf-style formatting without ever passing a
    /// dynamically typed value under the wrong C vararg representation.
    /// Shared by `String(format:)` and localized interpolation `specifier:`.
    ///
    /// `locale` is the difference between the two callers, and it is not
    /// cosmetic: `String(format: "%lld", 4097)` is `4097` while
    /// `String(format: "%lld", locale: .current, 4097)` is `4,097` in en_US.
    /// Swift's `String(format:)` is locale-LESS by definition, so the builtin
    /// passes nil; a localization key resolves under the current locale, so
    /// that path passes one.
    static func cFormattedString(
        _ format: String, values: [RuntimeValue], locale: Locale? = nil
    ) -> String {
        let directives = formatDirectives(format)
        var varargs: [CVarArg] = []
        for (index, value) in values.enumerated() {
            let directive = index < directives.count ? directives[index] : "@"
            if directive == "@" {
                // Object slots must always ride as Objective-C objects.
                if let i = value.intValue { varargs.append(NSNumber(value: i)) }
                else if let d = value.doubleValue { varargs.append(NSNumber(value: d)) }
                else if let s = value.stringValue { varargs.append(s as NSString) }
                else { varargs.append(value.stringified as NSString) }
            } else if "eEfgG".contains(directive) {
                varargs.append(value.doubleValue ?? 0)
            } else if "dDiuUxXo".contains(directive) {
                varargs.append(value.intValue ?? Int(value.doubleValue ?? 0))
            } else if directive == "s" {
                varargs.append(value.stringValue ?? value.stringified)
            } else if let i = value.intValue {
                varargs.append(i)
            } else if let d = value.doubleValue {
                varargs.append(d)
            } else if let s = value.stringValue {
                varargs.append(s as NSString)
            } else {
                varargs.append(value.stringified as NSString)
            }
        }
        return String(format: format, locale: locale, arguments: varargs)
    }
}
