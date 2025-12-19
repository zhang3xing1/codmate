import Foundation

/// Unified CLI environment configuration for embedded terminals and external shells
enum CLIEnvironment {
    static let defaultExecutableNames = ["codex", "claude", "gemini"]

    /// Standard PATH components that include common CLI tool locations
    /// - Includes: ~/.local/bin (claude), /opt/homebrew/bin (codex on M1),
    ///   /usr/local/bin (codex on Intel), and standard system paths
    static let standardPathComponents = [
        "$HOME/.bun/bin",
        "$HOME/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]

    // Detect common version-manager bins (nvm/fnm/volta/asdf/nodenv/nodebrew/etc.) that
    // actually contain codex/claude/gemini, so PATH stays lean but flexible.
    private static let detectedPathComponentsCache: [String] = detectPathComponents(
        for: defaultExecutableNames
    )

    /// Build an injected PATH string that prepends standard paths to existing PATH
    /// - Parameter additionalPaths: Optional array of additional paths to prepend
    /// - Returns: A PATH string ready to be exported or used in shell commands
    static func buildInjectedPATH(additionalPaths: [String] = []) -> String {
        let components = resolvedPathComponents(
            additionalPaths: additionalPaths,
            expandHome: false
        )
        return components.joined(separator: ":") + ":${PATH}"
    }

    /// Build an injected PATH string without preserving existing PATH
    /// Useful for ProcessInfo environment where PATH is merged differently
    /// - Parameter additionalPaths: Optional array of additional paths to prepend
    /// - Returns: A PATH string without ${PATH} suffix
    static func buildBasePATH(additionalPaths: [String] = []) -> String {
        let components = resolvedPathComponents(
            additionalPaths: additionalPaths,
            expandHome: true
        )
        return components.joined(separator: ":")
    }

    /// Standard locale environment variables for zh_CN UTF-8
    static let standardLocaleEnv: [String: String] = [
        "LANG": "zh_CN.UTF-8",
        "LC_ALL": "zh_CN.UTF-8",
        "LC_CTYPE": "zh_CN.UTF-8"
    ]

    /// Standard terminal environment
    static let standardTermEnv: [String: String] = [
        "TERM": "xterm-256color"
    ]

    /// Build export lines for shell scripts
    /// - Parameters:
    ///   - includeLocale: Include locale environment variables
    ///   - includeTerm: Include TERM environment variable
    ///   - additional: Additional environment variables to export
    /// - Returns: Array of export statements
    static func buildExportLines(
        includeLocale: Bool = true,
        includeTerm: Bool = true,
        additional: [String: String] = [:]
    ) -> [String] {
        var lines: [String] = []

        if includeLocale {
            for (key, value) in standardLocaleEnv {
                lines.append("export \(key)=\(value)")
            }
        }

        if includeTerm {
            for (key, value) in standardTermEnv {
                lines.append("export \(key)=\(value)")
            }
        }

        for (key, value) in additional {
            lines.append("export \(key)=\(value)")
        }

        return lines
    }

    static func resolvedPATHForCLI(sandboxed: Bool? = nil) -> String {
        let isSandboxed = sandboxed ?? (ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)
        let base = buildBasePATH()
        if isSandboxed { return base }
        if let shellPath = detectLoginShellPATH(), !shellPath.isEmpty {
            return shellPath
        }
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if current.isEmpty { return base }
        return base + ":" + current
    }

    static func resolveExecutablePath(_ name: String, path: String) -> String? {
        if let resolved = which(name, path: path) { return resolved }
        if let resolved = shellWhich(name) { return resolved }
        return manualResolve(name, path: path)
    }

    static func version(of name: String, path: String) -> String? {
        let candidates: [[String]] = [["--version"], ["version"], ["-V"], ["-v"]]
        for args in candidates {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [name] + args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            env["NO_COLOR"] = "1"
            proc.environment = env
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch { continue }

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            var out = (String(data: outData, encoding: .utf8) ?? "")
            let err = (String(data: errData, encoding: .utf8) ?? "")
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out = err
            }
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { continue }
            if let firstLine = out.split(separator: "\n").first { out = String(firstLine) }
            if let ver = firstVersionToken(in: out) { return ver }
            return String(out.prefix(48))
        }
        return nil
    }

    static func version(atExecutablePath executablePath: String, path: String) -> String? {
        let candidates: [[String]] = [["--version"], ["version"], ["-V"], ["-v"]]
        for args in candidates {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executablePath)
            proc.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            env["NO_COLOR"] = "1"
            proc.environment = env
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch { continue }

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            var out = (String(data: outData, encoding: .utf8) ?? "")
            let err = (String(data: errData, encoding: .utf8) ?? "")
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out = err
            }
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if out.isEmpty { continue }
            if let firstLine = out.split(separator: "\n").first { out = String(firstLine) }
            if let ver = firstVersionToken(in: out) { return ver }
            return String(out.prefix(48))
        }
        return nil
    }

    // MARK: - PATH resolution helpers
    private static func resolvedPathComponents(
        additionalPaths: [String],
        expandHome: Bool
    ) -> [String] {
        var components = additionalPaths
        components.append(contentsOf: detectedPathComponentsCache)
        components.append(contentsOf: standardPathComponents)
        let mapped = components.map { expandHome ? expandHomePath($0) : $0 }
        let filtered = mapped.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return dedupePreservingOrder(filtered)
    }

    private static func expandHomePath(_ path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        if path.contains("$HOME") {
            return path.replacingOccurrences(of: "$HOME", with: NSHomeDirectory())
        }
        return path
    }

    private static func dedupePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items where !item.isEmpty {
            if seen.insert(item).inserted {
                result.append(item)
            }
        }
        return result
    }

    private static func detectPathComponents(for executables: [String]) -> [String] {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()

        func containsExecutable(in dir: String) -> Bool {
            for name in executables {
                let candidate = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: candidate) { return true }
            }
            return false
        }

        func addIfExecutable(_ rawDir: String, to results: inout [String]) {
            let dir = expandHomePath(rawDir)
            guard !dir.isEmpty, fm.fileExists(atPath: dir) else { return }
            if containsExecutable(in: dir) { results.append(dir) }
        }

        func parseSemver(_ raw: String) -> [Int]? {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("v") { s.removeFirst() }
            let parts = s.split(separator: ".")
            guard !parts.isEmpty else { return nil }
            var out: [Int] = []
            for p in parts {
                guard let v = Int(p) else { return nil }
                out.append(v)
            }
            return out
        }

        func compareSemver(_ a: [Int], _ b: [Int]) -> Int {
            let count = max(a.count, b.count)
            for i in 0..<count {
                let av = i < a.count ? a[i] : 0
                let bv = i < b.count ? b[i] : 0
                if av != bv { return av > bv ? 1 : -1 }
            }
            return 0
        }

        func bestNvmBin(root: String) -> String? {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return nil }
            var candidates: [(bin: String, version: [Int]?, modified: Date?)] = []
            for name in entries {
                let dir = (root as NSString).appendingPathComponent(name)
                let bin = (dir as NSString).appendingPathComponent("bin")
                if !fm.fileExists(atPath: bin) { continue }
                if !containsExecutable(in: bin) { continue }
                let version = parseSemver(name)
                let modified =
                    (try? fm.attributesOfItem(atPath: bin)[.modificationDate]) as? Date
                candidates.append((bin: bin, version: version, modified: modified))
            }
            guard !candidates.isEmpty else { return nil }
            candidates.sort { lhs, rhs in
                switch (lhs.version, rhs.version) {
                case let (lv?, rv?):
                    return compareSemver(lv, rv) > 0
                case (nil, nil):
                    if let lm = lhs.modified, let rm = rhs.modified, lm != rm {
                        return lm > rm
                    }
                    return lhs.bin > rhs.bin
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                }
            }
            return candidates.first?.bin
        }

        var results: [String] = []

        if let nvmBin = env["NVM_BIN"], !nvmBin.isEmpty {
            addIfExecutable(nvmBin, to: &results)
        }
        if let npmPrefix = env["NPM_CONFIG_PREFIX"], !npmPrefix.isEmpty {
            addIfExecutable(npmPrefix + "/bin", to: &results)
        }
        if let pnpmHome = env["PNPM_HOME"], !pnpmHome.isEmpty {
            addIfExecutable(pnpmHome, to: &results)
        }
        if let bunInstall = env["BUN_INSTALL"], !bunInstall.isEmpty {
            addIfExecutable(bunInstall + "/bin", to: &results)
        }
        let nvmDir = env["NVM_DIR"] ?? (home + "/.nvm")
        let nvmVersions = (nvmDir as NSString).appendingPathComponent("versions/node")
        if let nvmBest = bestNvmBin(root: nvmVersions) {
            results.append(nvmBest)
        }

        let voltaHome = env["VOLTA_HOME"] ?? (home + "/.volta")
        addIfExecutable(voltaHome + "/bin", to: &results)

        let fnmDir = env["FNM_DIR"] ?? (home + "/.fnm")
        addIfExecutable(fnmDir + "/current/bin", to: &results)

        let asdfDir = env["ASDF_DATA_DIR"] ?? env["ASDF_DIR"] ?? (home + "/.asdf")
        addIfExecutable(asdfDir + "/shims", to: &results)

        let nodenvDir = env["NODENV_ROOT"] ?? (home + "/.nodenv")
        addIfExecutable(nodenvDir + "/shims", to: &results)

        let nodebrewDir = env["NODEBREW_ROOT"] ?? (home + "/.nodebrew")
        addIfExecutable(nodebrewDir + "/current/bin", to: &results)

        addIfExecutable(home + "/.npm-global/bin", to: &results)
        addIfExecutable(home + "/.npm-packages/bin", to: &results)
        addIfExecutable(home + "/.yarn/bin", to: &results)
        addIfExecutable(home + "/Library/pnpm", to: &results)
        addIfExecutable(home + "/.local/share/pnpm", to: &results)

        return dedupePreservingOrder(results)
    }

    private static func detectLoginShellPATH() -> String? {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lic", "printf %s \"$PATH\""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (str?.isEmpty == false) ? str : nil
    }

    private static func shellWhich(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lic", "command -v \(name) || which \(name)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (str?.isEmpty == false) ? str : nil
    }

    private static func which(_ name: String, path: String) -> String? {
        do {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["which", name]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            proc.environment = env
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty {
                    return str
                }
            }
        } catch { /* continue */ }
        return nil
    }

    private static func manualResolve(_ name: String, path: String) -> String? {
        let fm = FileManager.default
        for raw in path.split(separator: ":") {
            var dir = String(raw)
            if dir.isEmpty { continue }
            dir = expandHomePath(dir)
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func firstVersionToken(in line: String) -> String? {
        let separators = CharacterSet.whitespacesAndNewlines
        let tokens = line.components(separatedBy: separators).filter { !$0.isEmpty }
        for t in tokens {
            var s = t
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: ",;()[]{}"))
            let parts = s.split(separator: ".")
            if parts.count >= 2 && parts.count <= 4 && parts.allSatisfy({ $0.allSatisfy({ $0.isNumber }) || $0.contains("-") }) {
                let core = parts.prefix(3)
                if core.allSatisfy({ $0.allSatisfy({ $0.isNumber }) }) { return s }
            }
        }
        return nil
    }
}
