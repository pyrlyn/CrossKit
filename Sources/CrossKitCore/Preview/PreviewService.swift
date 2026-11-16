import Foundation

/// One rendered (or failed) preview.
public struct RenderedPreview: Codable, Equatable, Identifiable, Sendable {
    public var id: String { preview.id }
    public var preview: ComposePreview
    /// PNG on disk; nil when rendering failed.
    public var imagePath: String?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var error: String?

    public init(preview: ComposePreview, imagePath: String? = nil, pixelWidth: Int = 0, pixelHeight: Int = 0, error: String? = nil) {
        self.preview = preview
        self.imagePath = imagePath
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.error = error
    }
}

/// All previews of one file, rendered together.
public struct PreviewResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var filePath: String
    public var projectRoot: String
    /// Kotlin target whose classpath rendered the previews.
    public var target: String
    public var renderedAt: Date
    public var duration: TimeInterval
    public var density: Double
    public var previews: [RenderedPreview]
    /// The preview at the cursor.
    public var focusedID: String?
    /// Gradle and renderer output (for errors).
    public var log: String
    public var warning: String?

    public var fileName: String { (filePath as NSString).lastPathComponent }
    public var succeeded: Int { previews.filter { $0.error == nil }.count }

    public var summary: String {
        let failed = previews.count - succeeded
        var text = "Rendered \(succeeded) of \(previews.count) preview\(previews.count == 1 ? "" : "s") in \(fileName) (\(String(format: "%.1f", duration))s)"
        if failed > 0 { text += "; \(failed) failed" }
        return text
    }
}

public enum PreviewError: Error, LocalizedError, Equatable {
    case noPreviews(String)
    case notJVM(String)
    case buildFailed(String, output: String)
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noPreviews(let file): return "No @Preview functions in \(file). Annotate a @Composable function without required parameters with @Preview."
        case .notJVM(let detail): return detail
        case .buildFailed(let command, let output):
            let tail = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(25).joined(separator: "\n")
            return "Building the previews failed: \(command)\n\n\(tail)"
        case .renderFailed(let detail): return "Rendering the previews failed: \(detail)"
        }
    }
}

/// Renders Compose `@Preview` functions on the JVM: Gradle compiles the module and reports the JVM
/// runtime classpath (CrossKit's init script), then a small Java renderer draws each preview with
/// Compose Desktop's ImageComposeScene into a PNG.
public final class PreviewService: @unchecked Sendable {
    public let planner: LaunchPlanner
    public var directory: URL

    public init(planner: LaunchPlanner, directory: URL = SharedPaths.previewDirectory) {
        self.planner = planner
        self.directory = directory
    }

    public func render(file original: URL, text bufferText: String, cursorLine: Int) async throws -> PreviewResult {
        let file = URL(fileURLWithPath: LaunchPlanner.canonicalPath(original.path))
        let started = Date()
        let settings = planner.settings
        let resolver = planner.resolver
        let disk = (try? String(contentsOf: file, encoding: .utf8)) ?? bufferText
        let previews = PreviewDiscovery.discover(text: disk, fileName: file.lastPathComponent)
        guard !previews.isEmpty else { throw PreviewError.noPreviews(file.lastPathComponent) }

        // Which preview is at the cursor: found in the buffer, matched in the saved file by function.
        let clean = InlineAnnotations.cleanText(bufferText)
        let (_, line) = DebugService.matchSavedFile(file: file, text: bufferText, line: cursorLine)
        let bufferPreviews = PreviewDiscovery.discover(text: clean, fileName: file.lastPathComponent)
        let atCursor = PreviewDiscovery.preview(at: line, in: bufferPreviews) ?? PreviewDiscovery.preview(at: cursorLine, in: bufferPreviews)
        let focused = atCursor.flatMap { c in previews.first { $0.function == c.function && $0.index == c.index } } ?? previews.first

        // 1. Gradle: compile and print the JVM classpath.
        let root = resolver.projectRoot(for: file, language: .kotlin)
        let gradle = try planner.gradleExecutable(root: root)
        guard let project = KotlinProject.load(file: file, root: root) else {
            throw PreviewError.notJVM("Compose previews need a Gradle module (build.gradle(.kts)).")
        }
        let target: KotlinTargetInfo
        do { target = try project.target(for: file, choice: .jvm) } catch {
            throw PreviewError.notJVM("Compose previews render on the JVM, but \(project.moduleDirectory.lastPathComponent) has no JVM target. Add jvm() (or jvm(\"desktop\")) with compose.desktop.currentOs to kotlin { }.")
        }
        guard target.platform == .jvm else {
            throw PreviewError.notJVM("Compose previews render on the JVM, but \(file.lastPathComponent) belongs to the \(target.name) target. Put previews in commonMain or a JVM source set (jvmMain, desktopMain).")
        }
        let prefix = planner.gradleProjectPath(module: project.moduleDirectory, root: root)
        let initScript = try planner.writeGradleInitScript()
        var command = [gradle, "\(prefix)crossKitClasspath", "-q", "--console=plain", "-I", initScript.path]
        if project.isMultiplatform { command.append("-Pcrosskit.target=\(target.name)") }
        command += settings.gradleDaemonArguments + settings.testArguments(for: .kotlin)
        let env = resolver.environment(language: .kotlin, executable: URL(fileURLWithPath: gradle))
        let build = try await TestExecutor.run(
            TestCommand(kind: .gradle, executable: gradle, arguments: Array(command.dropFirst()), workingDirectory: root.path,
                        environment: env, reportsDirectory: nil),
            timeout: settings.testTimeout)
        let display = command.map(DebugService.shellQuote).joined(separator: " ")
        guard !build.timedOut, build.exitCode == 0,
              let cpLine = build.output.split(separator: "\n").last(where: { $0.hasPrefix("CROSSKIT_CLASSPATH=") }) else {
            if build.exitCode == 0 {
                throw PreviewError.buildFailed(display, output: build.output + "\nGradle reported no JVM classpath. Is the Kotlin JVM or Multiplatform plugin applied?")
            }
            throw PreviewError.buildFailed(display, output: build.output)
        }
        let classpath = String(cpLine.dropFirst("CROSSKIT_CLASSPATH=".count))
        if !classpath.contains("ui-desktop") && !classpath.contains("skiko") {
            throw PreviewError.notJVM("The JVM classpath of \(project.moduleDirectory.lastPathComponent) has no Compose Desktop. Add implementation(compose.desktop.currentOs) to the JVM (desktop) dependencies.")
        }

        // 2. Render.
        // The java chosen in settings (or detected), as for debugging.
        let java = try planner.debuggerPath(for: .jdb)
        let rendererClasses = try compileRenderer(java: java)
        let outDir = try outputDirectory(for: file)
        let density = settings.previewDensity
        let specs = previews.enumerated().map { i, p -> String in
            let background: String
            if let color = p.backgroundColor, color >> 24 != 0 {
                background = String(format: "%08X", color)
            } else if p.showBackground {
                background = "FFFFFFFF"
            } else {
                background = "none"
            }
            return ["\(i)", p.className, p.function, "\(p.widthDp ?? 0)", "\(p.heightDp ?? 0)", "\(density)", background].joined(separator: "\t")
        }
        let renderArgs = ["-Djava.awt.headless=true", "-cp", rendererClasses.path + ":" + classpath, PreviewRendererSource.className, outDir.path] + specs
        var javaEnv = resolver.environment(language: .kotlin, executable: java)
        javaEnv["JAVA_TOOL_OPTIONS"] = nil
        let render = try await TestExecutor.run(
            TestCommand(kind: .gradle, executable: java.path, arguments: renderArgs, workingDirectory: root.path,
                        environment: javaEnv, reportsDirectory: nil),
            timeout: 180)
        if render.timedOut { throw PreviewError.renderFailed("the renderer did not finish within 180s.") }
        var results = previews.map { RenderedPreview(preview: $0, error: "The renderer did not report this preview.") }
        for line in render.output.split(separator: "\n") where line.hasPrefix("CROSSKIT_PREVIEW ") {
            let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
            guard parts.count >= 3, let i = Int(parts[1]), results.indices.contains(i) else { continue }
            if parts[2] == "OK" {
                let size = parts.count > 3 ? parts[3].split(separator: " ").compactMap { Int($0) } : []
                results[i].imagePath = outDir.appendingPathComponent("\(i).png").path
                results[i].pixelWidth = size.first ?? 0
                results[i].pixelHeight = size.count > 1 ? size[1] : 0
                results[i].error = nil
            } else {
                results[i].error = parts.count > 3 ? parts[3] : "unknown error"
            }
        }
        if render.exitCode != 0, results.allSatisfy({ $0.error != nil }) {
            let tail = render.output.split(separator: "\n").suffix(15).joined(separator: "\n")
            throw PreviewError.renderFailed("java exited with \(render.exitCode.map(String.init) ?? "a signal").\n\(tail)")
        }
        var result = PreviewResult(
            id: UUID(), filePath: file.path, projectRoot: root.path, target: target.displayName, renderedAt: Date(),
            duration: Date().timeIntervalSince(started), density: density, previews: results, focusedID: focused?.id,
            log: "$ \(display)\n\(build.output)\n$ java … \(PreviewRendererSource.className)\n\(render.output)")
        if disk.trimmingCharacters(in: .whitespacesAndNewlines) != clean.trimmingCharacters(in: .whitespacesAndNewlines) {
            result.warning = "The editor buffer has unsaved changes; previews show the saved file."
        }
        return result
    }

    /// Compiles the renderer once per source version and JDK (`javac` next to `java`). The JDK is part of the
    /// cache key because classes compiled by a newer JDK do not load on an older `java` chosen later in settings.
    /// Compilation goes to a scratch directory that is renamed into place, so concurrent renders never load a
    /// half-written class file.
    func compileRenderer(java: URL) throws -> URL {
        let fm = FileManager.default
        var hash: UInt64 = 1469598103934665603
        for b in (PreviewRendererSource.java + "\u{0}" + java.resolvingSymlinksInPath().path).utf8 {
            hash = (hash ^ UInt64(b)) &* 1099511628211
        }
        let dir = directory.appendingPathComponent("renderer-\(String(hash, radix: 36))")
        let classFile = dir.appendingPathComponent("\(PreviewRendererSource.className).class")
        if fm.fileExists(atPath: classFile.path) { return dir }
        let javac = java.deletingLastPathComponent().appendingPathComponent("javac")
        guard fm.isExecutableFile(atPath: javac.path) else {
            throw DebugError.toolNotFound("javac", hint: "CrossKit needs a full JDK (not a JRE) to compile its preview renderer. \(DebuggerLocator.installHint(.jdb))")
        }
        let scratch = directory.appendingPathComponent("renderer-tmp-\(UUID().uuidString.prefix(8).lowercased())")
        defer { try? fm.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("src/\(PreviewRendererSource.className).java")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PreviewRendererSource.java.write(to: source, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = javac
        process.arguments = ["-nowarn", "-d", scratch.path, source.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PreviewError.renderFailed("javac failed: \(output)") }
        do {
            try fm.moveItem(at: scratch, to: dir)
        } catch {
            // Another render may have finished compiling the same renderer first.
            guard fm.fileExists(atPath: classFile.path) else { throw error }
        }
        return dir
    }

    /// A fresh directory per render; older renders of the same file are removed.
    func outputDirectory(for file: URL) throws -> URL {
        var hash: UInt64 = 1469598103934665603
        for b in file.path.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        let base = directory.appendingPathComponent("renders/\(file.deletingPathExtension().lastPathComponent)-\(String(hash, radix: 36))")
        try? FileManager.default.removeItem(at: base)
        let dir = base.appendingPathComponent(UUID().uuidString.prefix(8).lowercased())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
