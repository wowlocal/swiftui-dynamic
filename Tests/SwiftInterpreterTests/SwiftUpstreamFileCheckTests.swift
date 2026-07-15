import Foundation
import Testing

enum SwiftUpstreamFileCheck {
    enum Kind: String {
        case check = "CHECK"
        case next = "CHECK-NEXT"
        case same = "CHECK-SAME"
        case dag = "CHECK-DAG"
        case not = "CHECK-NOT"
        case label = "CHECK-LABEL"
    }

    struct Directive {
        let kind: Kind
        let pattern: String
        let sourceLine: Int
    }

    enum CheckError: Error, CustomStringConvertible {
        case noDirectives
        case emptyPattern(line: Int)
        case unsupportedPattern(line: Int, pattern: String)
        case unsupportedDirective(line: Int, directive: String)

        var description: String {
            switch self {
            case .noDirectives:
                return "fixture contains no active CHECK directives"
            case .emptyPattern(let line):
                return "empty CHECK pattern at source line \(line)"
            case .unsupportedPattern(let line, let pattern):
                return "unsupported FileCheck regex/variable at source line "
                    + "\(line): \(String(reflecting: pattern))"
            case .unsupportedDirective(let line, let directive):
                return "unsupported FileCheck directive at source line "
                    + "\(line): \(directive)"
            }
        }
    }

    private struct Match: Hashable {
        let start: Int
        let end: Int
        let line: Int
    }

    private struct Document {
        let text: NSString
        let lines: [NSRange]

        init(_ rawOutput: String) {
            let normalized = rawOutput.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            text = normalized as NSString

            var ranges: [NSRange] = []
            var start = 0
            for line in normalized.split(
                separator: "\n", omittingEmptySubsequences: false
            ) {
                let length = String(line).utf16.count
                ranges.append(NSRange(location: start, length: length))
                start += length + 1
            }
            lines = ranges
        }

        func line(containing offset: Int) -> Int {
            for (index, range) in lines.enumerated()
            where offset <= NSMaxRange(range) {
                return index
            }
            return max(0, lines.count - 1)
        }

        func first(
            _ pattern: String,
            in range: NSRange,
            excluding used: Set<Match> = []
        ) -> Match? {
            guard range.location >= 0,
                  range.length >= 0,
                  NSMaxRange(range) <= text.length else {
                return nil
            }
            var remaining = range
            while remaining.length >= 0 {
                let found = text.range(of: pattern, options: [], range: remaining)
                guard found.location != NSNotFound else { return nil }
                let match = Match(
                    start: found.location,
                    end: NSMaxRange(found),
                    line: line(containing: found.location))
                if !used.contains(match) { return match }
                let next = NSMaxRange(found)
                guard next <= NSMaxRange(range), next > remaining.location else {
                    return nil
                }
                remaining = NSRange(
                    location: next,
                    length: NSMaxRange(range) - next)
            }
            return nil
        }

        func contains(_ pattern: String, from start: Int, to end: Int) -> Bool {
            guard start <= end else { return false }
            return first(
                pattern,
                in: NSRange(location: start, length: end - start)) != nil
        }
    }

    static func parse(_ source: String) throws -> [Directive] {
        let kinds: [(suffix: String, kind: Kind)] = [
            ("-NEXT:", .next),
            ("-SAME:", .same),
            ("-DAG:", .dag),
            ("-NOT:", .not),
            ("-LABEL:", .label),
            (":", .check),
        ]
        var directives: [Directive] = []
        for (offset, rawLine) in source.split(
            separator: "\n", omittingEmptySubsequences: false
        ).enumerated() {
            let line = String(rawLine)
            guard let marker = line.range(of: "// CHECK") else { continue }
            let suffix = String(line[marker.upperBound...])
            guard let parsed = kinds.first(where: { suffix.hasPrefix($0.suffix) }) else {
                if suffix.hasPrefix("-") {
                    throw CheckError.unsupportedDirective(
                        line: offset + 1, directive: "CHECK" + suffix)
                }
                continue
            }
            let pattern = suffix.dropFirst(parsed.suffix.count)
                .trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else {
                throw CheckError.emptyPattern(line: offset + 1)
            }
            guard !pattern.contains("{{"), !pattern.contains("[[") else {
                throw CheckError.unsupportedPattern(
                    line: offset + 1, pattern: pattern)
            }
            directives.append(Directive(
                kind: parsed.kind,
                pattern: pattern,
                sourceLine: offset + 1))
        }
        guard !directives.isEmpty else { throw CheckError.noDirectives }
        return directives
    }

    static func violations(source: String, output: String) throws -> [String] {
        let directives = try parse(source)
        let document = Document(output)
        var problems: [String] = []
        var cursor = 0
        var lastPositive: Match?
        var negativeRegionStart = 0
        var pendingNegative: [Directive] = []

        func validateNegatives(until end: Int) {
            for directive in pendingNegative
            where document.contains(
                directive.pattern, from: negativeRegionStart, to: end
            ) {
                problems.append(
                    "CHECK-NOT at source line \(directive.sourceLine) matched "
                        + String(reflecting: directive.pattern))
            }
            pendingNegative.removeAll()
        }

        func accept(_ match: Match) {
            validateNegatives(until: match.start)
            cursor = match.end
            negativeRegionStart = match.end
            lastPositive = match
        }

        var index = 0
        while index < directives.count {
            let directive = directives[index]
            switch directive.kind {
            case .not:
                pendingNegative.append(directive)
                index += 1

            case .dag:
                var group: [Directive] = []
                while index < directives.count,
                      directives[index].kind == .dag {
                    group.append(directives[index])
                    index += 1
                }
                var used: Set<Match> = []
                var matches: [Match] = []
                for item in group {
                    let range = NSRange(
                        location: cursor,
                        length: document.text.length - cursor)
                    if let match = document.first(
                        item.pattern, in: range, excluding: used
                    ) {
                        used.insert(match)
                        matches.append(match)
                    } else {
                        problems.append(
                            "CHECK-DAG at source line \(item.sourceLine) did not "
                                + "match \(String(reflecting: item.pattern))")
                    }
                }
                if let first = matches.min(by: { $0.start < $1.start }),
                   let last = matches.max(by: { $0.end < $1.end }) {
                    validateNegatives(until: first.start)
                    cursor = last.end
                    negativeRegionStart = last.end
                    lastPositive = last
                }

            case .check, .label:
                let range = NSRange(
                    location: cursor,
                    length: document.text.length - cursor)
                if let match = document.first(directive.pattern, in: range) {
                    accept(match)
                } else {
                    problems.append(
                        "\(directive.kind.rawValue) at source line "
                            + "\(directive.sourceLine) did not match "
                            + String(reflecting: directive.pattern))
                }
                index += 1

            case .next:
                guard let previous = lastPositive else {
                    problems.append(
                        "CHECK-NEXT at source line \(directive.sourceLine) has "
                            + "no previous positive match")
                    index += 1
                    continue
                }
                let nextLine = previous.line + 1
                guard document.lines.indices.contains(nextLine) else {
                    problems.append(
                        "CHECK-NEXT at source line \(directive.sourceLine) "
                            + "expected another output line")
                    index += 1
                    continue
                }
                if let match = document.first(
                    directive.pattern, in: document.lines[nextLine]
                ) {
                    accept(match)
                } else {
                    problems.append(
                        "CHECK-NEXT at source line \(directive.sourceLine) did "
                            + "not match output line \(nextLine + 1): "
                            + String(reflecting: directive.pattern))
                }
                index += 1

            case .same:
                guard let previous = lastPositive else {
                    problems.append(
                        "CHECK-SAME at source line \(directive.sourceLine) has "
                            + "no previous positive match")
                    index += 1
                    continue
                }
                let lineRange = document.lines[previous.line]
                let start = max(previous.end, lineRange.location)
                let range = NSRange(
                    location: start,
                    length: NSMaxRange(lineRange) - start)
                if let match = document.first(directive.pattern, in: range) {
                    accept(match)
                } else {
                    problems.append(
                        "CHECK-SAME at source line \(directive.sourceLine) did "
                            + "not match \(String(reflecting: directive.pattern))")
                }
                index += 1
            }
        }
        validateNegatives(until: document.text.length)
        return problems
    }

    /// Matches every plain CHECK directive against a distinct output range
    /// without imposing source order. This is intentionally a separate
    /// manifest oracle: it is valid only when native characterization proves
    /// that the observations are a multiset rather than a happens-before
    /// sequence. NEXT/SAME/DAG/NOT/LABEL must keep the ordered matcher above.
    static func unorderedViolations(
        source: String, output: String
    ) throws -> [String] {
        let directives = try parse(source)
        if let directive = directives.first(where: { $0.kind != .check }) {
            throw CheckError.unsupportedDirective(
                line: directive.sourceLine,
                directive: "unordered \(directive.kind.rawValue)")
        }

        let document = Document(output)
        let range = NSRange(location: 0, length: document.text.length)
        var used: Set<Match> = []
        var problems: [String] = []
        for directive in directives {
            if let match = document.first(
                directive.pattern, in: range, excluding: used
            ) {
                used.insert(match)
            } else {
                problems.append(
                    "unordered CHECK at source line \(directive.sourceLine) "
                        + "did not match a distinct "
                        + String(reflecting: directive.pattern))
            }
        }
        return problems
    }
}

@Suite("Swift upstream FileCheck subset")
struct SwiftUpstreamFileCheckTests {
    @Test func sequentialNextSameAndNotPass() throws {
        let source = """
        // CHECK: alpha
        // CHECK-SAME: beta
        // CHECK-NEXT: gamma
        // CHECK-NOT: forbidden
        // CHECK: omega
        """
        let output = "alpha beta\ngamma\nallowed\nomega\n"
        #expect(try SwiftUpstreamFileCheck.violations(
            source: source, output: output).isEmpty)
    }

    @Test func dagAcceptsDifferentOutputOrder() throws {
        let source = """
        // CHECK-DAG: first
        // CHECK-DAG: second
        // CHECK-DAG: third
        """
        let output = "third\nfirst\nsecond\n"
        #expect(try SwiftUpstreamFileCheck.violations(
            source: source, output: output).isEmpty)
    }

    @Test func unorderedChecksPreserveMultiplicityWithoutSchedulerOrder() throws {
        let source = """
        // CHECK: first
        // CHECK: second
        // CHECK: repeated
        // CHECK: repeated
        """
        let reversed = "second\nrepeated\nfirst\nrepeated\n"
        #expect(!(try SwiftUpstreamFileCheck.violations(
            source: source, output: reversed).isEmpty))
        #expect(try SwiftUpstreamFileCheck.unorderedViolations(
            source: source, output: reversed).isEmpty)

        let missingDuplicate = "second\nrepeated\nfirst\n"
        let problems = try SwiftUpstreamFileCheck.unorderedViolations(
            source: source, output: missingDuplicate)
        #expect(problems.count == 1)
        #expect(problems[0].contains("distinct"))
    }

    @Test func reportsMissingAndForbiddenOutput() throws {
        let source = """
        // CHECK: begin
        // CHECK-NOT: forbidden
        // CHECK: missing
        """
        let problems = try SwiftUpstreamFileCheck.violations(
            source: source, output: "begin\nforbidden\nend\n")
        #expect(problems.count == 2)
        #expect(problems.contains { $0.contains("CHECK-NOT") })
        #expect(problems.contains { $0.contains("did not match") })
    }

    @Test func rejectsFileCheckVariablesInsteadOfWeakeningThem() {
        do {
            _ = try SwiftUpstreamFileCheck.parse(
                "// CHECK: value [[ID:[0-9]+]]")
            Issue.record("FileCheck variable unexpectedly accepted")
        } catch let error as SwiftUpstreamFileCheck.CheckError {
            #expect(error.description.contains("unsupported"))
        } catch {
            Issue.record("unexpected matcher error: \(error)")
        }
    }
}
