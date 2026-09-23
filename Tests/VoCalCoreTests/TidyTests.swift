import Foundation
import Testing

// The ratchet table: mechanical rules over the repository as text, run in the fast loop
// (`swift test`, so `scripts/check` and CI). Rows are data; one enforcer runs every row;
// ceilings only ever go down. Each rule states its kind above it (docs/restructure/
// 01-ratchets.md): an INCIDENT rule carries the date and the symptom, a SUPERSESSION rule
// names the replacement in its description, a BOUNDARY rule cites the layer contract.
// Scans only tracked files (`git ls-files`); comment lines are skipped. The table and
// docs/ sit outside every scan root on purpose: a rule must be able to name the banned
// shape in its own comment.

@Suite("TidyRatchets")
struct TidyRatchetTests {
    // BOUNDARY: Package.swift declares the libraries for iOS and macOS, and scripts/check
    // runs them on a Mac with no iOS SDK in the loop. A UI or platform framework import
    // in Sources/ would move the fast loop onto the simulator (AGENTS.md verification tiers).
    static let libraryBannedImports = ["UIKit", "SwiftUI", "AVFoundation", "Supabase"]

    // SUPERSESSION rules for concurrency: the app is Swift 6 strict-concurrency; a dispatch
    // queue or a detached task drops the isolation the compiler checks.
    // BOUNDARY: ARCHITECTURE.md capture-path isolation, the mic-hot path must not depend on
    // anything that serves another concern (delete the subsystem: capture still works).
    // BOUNDARY: docs/DESIGN.md, views read VoCalTheme tokens only, never a raw color.
    // INCIDENT (TIDY-WORDS-001): Lorenzo's product-wide rule, no em dashes in copy a person
    // reads. The 2026-08-23 sweep landed on feature/help-tour and never reached main; on
    // 2026-09-23 four literals were still in the app and five in the API copy.
    static let patternRules: [PatternRatchetRule] = [
        .init(
            id: "TIDY-CONC-001",
            description: "Use an actor, @MainActor or a Task; DispatchQueue hops lose the compiler-checked isolation.",
            roots: ["Sources", "apps/ios"],
            regex: #"\bDispatchQueue\b"#,
            maxViolations: 0
        ),
        .init(
            id: "TIDY-CONC-002",
            description: "Use a structured Task (or Task { } on the owning actor); Task.detached escapes every isolation.",
            roots: ["Sources", "apps/ios"],
            regex: #"\bTask\.detached\b"#,
            maxViolations: 0
        ),
        .init(
            id: "TIDY-CONC-003",
            description: "Do not add @unchecked Sendable; the two bridges to pre-Sendable frameworks are the whole set (see namedExceptions).",
            roots: ["Sources", "apps/ios"],
            regex: #"@unchecked\s+Sendable"#,
            maxViolations: 2,
            expectedPaths: [
                "apps/ios/VoCal/Services/Auth/AuthTokenStore.swift",
                "apps/ios/VoCal/Services/NudgeNotificationService.swift",
            ]
        ),
        .init(
            id: "TIDY-CAPTURE-001",
            description: "The capture path (apps/ios/VoCal/Voice) must not reach the API client, auth, Supabase or a dashboard model; capture must work with every one of them deleted.",
            roots: ["apps/ios/VoCal/Voice"],
            regex: #"\b(APIClient|URLSession|AuthService|SupabaseAuth|TodayViewModel|NudgeCenter)\b|^\s*import\s+Supabase\b"#,
            maxViolations: 0
        ),
        .init(
            id: "TIDY-INK-001",
            description: "Read colors from VoCalTheme tokens; no raw hex or Color(red:) in surface code.",
            roots: ["apps/ios"],
            regex: #"#[0-9A-Fa-f]{6}\b|\bColor\(red:|\bUIColor\(red:"#,
            maxViolations: 0,
            excluding: ["apps/ios/VoCal/Theme/VoCalTheme.swift"]
        ),
        .init(
            id: "TIDY-CONC-004",
            description: "A CHHapticEngine reset or stopped handler is @Sendable; CoreHaptics calls it on its own queue and a main-actor closure traps there (Serein, three crashes on 2026-09-02).",
            roots: ["apps/ios"],
            regex: #"(resetHandler|stoppedHandler)\s*=\s*\{\s*(?!@Sendable)"#,
            maxViolations: 0
        ),
        .init(
            id: "TIDY-ADDR-001",
            description: "The confirmed-confidence bar has one address, ConfidenceBar.confirmed in VoCalCore; no view spells 0.93 or 0.94.",
            roots: ["apps/ios"],
            regex: #"\b0\.9[34]\b"#,
            maxViolations: 0
        ),
        .init(
            id: "TIDY-CLAIM-001",
            description: "The claim words (Saved, Saving, Listening, Logged) are string literals only in VoiceLogState.swift (ClaimCopy); a view renders them from the state that licenses them.",
            roots: ["apps/ios"],
            regex: #""(Saved|Listening|Logged|Saving\\u\{2026\})""#,
            maxViolations: 0,
            excluding: ["apps/ios/VoCal/ViewModels/VoiceLogState.swift"]
        ),
        .init(
            id: "TIDY-WORDS-001",
            description: "No em dash in a string a person reads; use a period, a comma or 'to'.",
            roots: ["Sources", "apps/ios"],
            regex: "\"[^\"]*\u{2014}[^\"]*\"",
            maxViolations: 0
        ),
    ]

    @Test("SPM libraries stay platform-free")
    func libraryBoundaries() throws {
        let scanner = try RepositoryScanner()
        try enforcePatternRules(
            Self.libraryBannedImports.map { framework in
                PatternRatchetRule(
                    id: "TIDY-SPM-\(framework.uppercased())-001",
                    description: "Sources/ must not import \(framework); the libraries run in scripts/check without the iOS SDK.",
                    roots: ["Sources"],
                    regex: #"^\s*import\s+\#(framework)\b"#,
                    maxViolations: 0
                )
            },
            scanner: scanner
        )
    }

    @Test("Pattern ratchets over the app and the libraries")
    func patternRatchets() throws {
        try enforcePatternRules(Self.patternRules, scanner: RepositoryScanner())
    }

    // BOUNDARY: apps/ios/AGENTS.md, the .xcodeproj is generated from project.yml and
    // gitignored; a tracked generated output is the one thing a merge conflict can silently
    // resurrect (the stale project that failed bin/ios-app-build on 2026-09-23).
    @Test("Generated outputs and build products stay untracked")
    func generatedOutputsUntracked() throws {
        let tracked = try RepositoryScanner().trackedFiles()
        let leaked = tracked.filter {
            $0.contains(".xcodeproj/") || $0.hasPrefix("DerivedData/") || $0.hasPrefix(".build/")
                || $0.contains("/__pycache__/") || $0.contains("/.venv/")
        }
        #expect(leaked.isEmpty, "[TIDY-XCG-001] generated outputs are tracked:\n\(leaked.joined(separator: "\n"))")
    }

    // BOUNDARY (3.4, make the gate outlive you): the verification ladder is wired into CI
    // and the push hook by name. This is the one kind of floor the table allows: a
    // capability that must exist at all. Deleting a step to make a build pass fails here.
    @Test("CI and the push hook still invoke every rung of the ladder")
    func verificationWiring() throws {
        let scanner = try RepositoryScanner()
        let ci = try scanner.readText(relativePath: ".github/workflows/ci.yml")
        for rung in ["scripts/check-api", "scripts/parser-eval", "swift test", "bin/voice-dst --smoke", "bin/ios-app-build", "bin/ios-sim-voice-test"] {
            #expect(ci.contains(rung), "[TIDY-CI-001] .github/workflows/ci.yml no longer invokes \(rung)")
        }
        // INCIDENT (2026-09-23): the previous workflow fell back to /Applications/Xcode.app
        // when Xcode 26.2 was absent and never printed the toolchain it built with.
        #expect(!ci.contains("|| sudo xcode-select"), "[TIDY-CI-002] the CI toolchain step must fail, never fall back silently")
        #expect(ci.contains("xcodebuild -version"), "[TIDY-CI-002] the CI toolchain step must print the toolchain it selected")
        let hook = try scanner.readText(relativePath: ".githooks/pre-push")
        #expect(hook.contains("scripts/check"), "[TIDY-HOOK-001] .githooks/pre-push no longer runs scripts/check")
        let tracked = try scanner.trackedFiles()
        #expect(tracked.contains(".githooks/pre-push"), "[TIDY-HOOK-001] .githooks/pre-push is not tracked")
        #expect(FileManager.default.isExecutableFile(atPath: scanner.root.appendingPathComponent(".githooks/pre-push").path), "[TIDY-HOOK-001] .githooks/pre-push must be executable")
        // SUPERSESSION: the uninstalled pre-commit config and its swiftlint wrapper were a gate
        // on paper only (F19); the push hook replaced them.
        #expect(!tracked.contains(".pre-commit-config.yaml"), "[TIDY-HOOK-002] use .githooks/pre-push, not a pre-commit config nobody installs")
        #expect(!tracked.contains("scripts/run_swiftlint.sh"), "[TIDY-HOOK-002] swiftlint is not part of this repo's ladder")
    }

    @Test("Every rule is well formed")
    func metaTest() throws {
        let scanner = try RepositoryScanner()
        let libraryRules = Self.libraryBannedImports.map {
            PatternRatchetRule(id: "TIDY-SPM-\($0.uppercased())-001", description: "", roots: ["Sources"], regex: "x", maxViolations: 0)
        }
        let all = Self.patternRules + libraryRules
        let ids = all.map(\.id)
        #expect(Set(ids).count == ids.count, "rule ids must be unique: \(ids)")
        let shape = try NSRegularExpression(pattern: #"^TIDY-[A-Z]+(-[A-Z]+)?-\d{3}$"#)
        for rule in all {
            let range = NSRange(rule.id.startIndex..<rule.id.endIndex, in: rule.id)
            #expect(shape.firstMatch(in: rule.id, range: range) != nil, "malformed id \(rule.id)")
            #expect((try? NSRegularExpression(pattern: rule.regex)) != nil, "\(rule.id): pattern does not compile")
            for root in rule.roots {
                #expect(FileManager.default.fileExists(atPath: scanner.root.appendingPathComponent(root).path), "\(rule.id): root \(root) does not exist")
            }
            if rule.maxViolations > 0 {
                #expect(rule.expectedPaths != nil, "\(rule.id): a nonzero ceiling must name its exact path set")
            }
        }
    }
}

// MARK: - The enforcer

struct PatternRatchetRule {
    let id: String
    let description: String
    /// Repo-relative directories, or single file paths.
    let roots: [String]
    let regex: String
    /// Ceiling, never raised. A nonzero ceiling names the exact offending files.
    let maxViolations: Int
    var expectedPaths: [String]? = nil
    /// Repo-relative files inside the roots that the rule does not scan (the one
    /// legitimate address of a banned shape, named so it cannot silently multiply).
    var excluding: [String] = []
}

private struct TidyViolation: Comparable {
    let path: String
    let line: Int
    let details: String

    static func < (lhs: TidyViolation, rhs: TidyViolation) -> Bool {
        (lhs.path, lhs.line, lhs.details) < (rhs.path, rhs.line, rhs.details)
    }
}

private func enforcePatternRules(_ rules: [PatternRatchetRule], scanner: RepositoryScanner) throws {
    for rule in rules {
        let violations = try scanner.findPatternViolations(rule: rule)
        #expect(
            violations.count <= rule.maxViolations,
            """
            [\(rule.id)] \(rule.description)
            observed=\(violations.count) max=\(rule.maxViolations)
            \(formatViolations(violations))
            """
        )
        if let expected = rule.expectedPaths {
            let observed = Set(violations.map(\.path))
            #expect(
                observed == Set(expected),
                """
                [\(rule.id)] the named exception set changed (a violation may not be traded for another).
                observed=\(observed.sorted()) expected=\(expected.sorted())
                """
            )
        }
    }
}

private func formatViolations(_ violations: [TidyViolation]) -> String {
    if violations.isEmpty { return "No violations." }
    return violations.prefix(50).map { "\($0.path):\($0.line): \($0.details)" }.joined(separator: "\n")
}

final class RepositoryScanner {
    let root: URL
    private var fileCache: [String: String] = [:]
    private var trackedCache: [String]?

    init() throws {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                throw NSError(domain: "TidyRatchetTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "repository root not found above \(#filePath)"])
            }
            url = parent
        }
        root = url
    }

    func trackedFiles() throws -> [String] {
        if let trackedCache { return trackedCache }
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "ls-files"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TidyRatchetTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "git ls-files failed"])
        }
        let files = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n").map(String.init)
            .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
            .sorted()
        trackedCache = files
        return files
    }

    /// A tracked or untracked repo file as text (for wiring assertions over YAML and hooks).
    func readText(relativePath: String) throws -> String {
        try text(of: relativePath)
    }

    private func text(of relativePath: String) throws -> String {
        if let cached = fileCache[relativePath] { return cached }
        let text = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        fileCache[relativePath] = text
        return text
    }

    /// Tracked Swift files under the roots (a root may be a single file), minus exclusions.
    func swiftFiles(roots: [String], excluding: [String] = []) throws -> [String] {
        let excluded = Set(excluding)
        return try trackedFiles().filter { path in
            path.hasSuffix(".swift") && !excluded.contains(path)
                && roots.contains { root in path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        }
    }

    fileprivate func findPatternViolations(rule: PatternRatchetRule) throws -> [TidyViolation] {
        let regex = try NSRegularExpression(pattern: rule.regex)
        var violations: [TidyViolation] = []
        for path in try swiftFiles(roots: rule.roots, excluding: rule.excluding) {
            for (index, line) in try text(of: path).components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") { continue }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    violations.append(TidyViolation(path: path, line: index + 1, details: trimmed))
                }
            }
        }
        return violations.sorted()
    }
}
