# CrossKit

CrossKit is an Xcode Source Editor Extension that bridges Xcode to Language Server Protocol (LSP) servers for **Kotlin**, **Zig**, and **Rust**:

| Language | Server | File extensions (default) |
|---|---|---|
| Kotlin | [`kotlin-language-server`](https://github.com/fwcd/kotlin-language-server) | `.kt`, `.kts` |
| Zig | [`zls`](https://github.com/zigtools/zls) | `.zig` |
| Rust | [`rust-analyzer`](https://rust-analyzer.github.io) | `.rs` |

It provides completion, go to definition, find references, diagnostics, and hover info as **Editor › CrossKit** menu commands, which you can bind to keys. It also runs tests with each language's native runner (`zig test` / `zig build test`, `cargo test` / `cargo nextest`, JUnit 5 through Gradle) and starts debug sessions (lldb-dap, lldb, CodeLLDB, or JDWP with jdb). A detailed user guide is in [docs/GUIDE.md](docs/GUIDE.md). Everything is configured in a native settings window, so you never edit a config file. CrossKit makes no network calls; it only launches local server binaries.

## How it works

```
Xcode ──XcodeKit──▶ CrossKitExtension.appex (sandboxed)
                         │  CFMessagePort "group.dev.pyrlyn.CrossKit.bridge" (JSON, Content-Length framed)
                         ▼
                    CrossKit.app (host, not sandboxed, menu bar + settings window)
                         │  stdio, JSON-RPC 2.0 with LSP Content-Length framing
                         ▼
          kotlin-language-server / zls / rust-analyzer (one per language + workspace root)
```

* **Why a host app?** Apple requires one to ship the extension. Xcode also only loads *sandboxed* extensions, and a sandboxed process cannot spawn arbitrary binaries. So all process management lives in the host app, which is deliberately **not sandboxed**. The extension only collects the buffer and the cursor, sends a request, and applies the resulting edits.
* **IPC.** The extension and the host share the App Group `group.dev.pyrlyn.CrossKit`. The sandbox lets the extension look up Mach ports prefixed with that group, so the host serves a `CFMessagePort` named `group.dev.pyrlyn.CrossKit.bridge`. No files or sockets are shared, which keeps macOS container-protection prompts out of the way. If the host is not running, the extension launches it in the background.
* **Settings.** They live in `UserDefaults(suiteName: "group.dev.pyrlyn.CrossKit")`, the shared App Group store. The host enforces them, and the extension reads the same store. Defaults are built in: every language is on, every feature is on, binaries are auto-detected, and idle servers stop after 15 minutes.
* **Server lifecycle** (`ServerManager`):
  * A server starts lazily on the first request for its language and workspace root, then completes the `initialize`/`initialized` handshake.
  * Workspace roots are detected from `Cargo.toml`, `build.zig`, `settings.gradle(.kts)`, `build.gradle(.kts)`, or `pom.xml`, then from `.git`, then from the file's folder.
  * A crashed server restarts with exponential backoff (1, 2, 4, 8, 16 s). After 5 crashes in 5 minutes it stays down and the error appears in settings.
  * Idle servers shut down after the configured timeout.
  * Shutdown is clean: `shutdown` → `exit`, then SIGTERM, then SIGKILL. Each server runs in its own process group, so helpers such as rust-analyzer's proc-macro server or zls's `zig build` runner are reaped too. Quitting the host stops everything.

## Settings window

Open **CrossKit.app**, the menu bar icon, or **Editor › CrossKit › Open CrossKit Settings** in Xcode. For each language you can:

* **Turn the language on or off.**
* **Pick the server binary.** CrossKit auto-detects it by default. You can also pick one from the list of detected binaries, choose a file with **Choose…**, or go back to auto-detection.
* **Turn individual features on or off:** completion, go to definition, find references, diagnostics, hover, running tests, and debugging.
* **Configure debugging:** the debugger (auto-detected or forced), its binary, and the Kotlin JDWP port. Per-project launch configurations are listed and editable at the bottom of the window.
* **Configure test running:** the runner (auto-detected or forced), the test tool binary (auto-detected or chosen), and extra arguments such as `--offline`.
* **See live server status:** running (with pid and workspace), starting, restarting, stopped, error, or not found. The last error is shown with the tail of the server's stderr, next to **Restart** and **Stop** buttons.

The idle timeout and the test timeout are global settings. Changes are saved immediately; there is no Save button.

### Auto-detection order

Auto-detection checks these locations in order and uses the first executable it finds:

1. Rust only: `~/.rustup/toolchains/*/bin/rust-analyzer`, newest toolchain first.
2. mise installs, newest version first, for example `~/.local/share/mise/installs/zls/<ver>/zls` or `…/github-fwcd-kotlin-language-server/<ver>/bin/kotlin-language-server`. `MISE_DATA_DIR` is respected.
3. `~/.cargo/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, and `~/.sdkman/candidates/*/current/bin`.
4. mise shims (`~/.local/share/mise/shims`), used only if the tool is actually installed.
5. Directories on `PATH`.

Servers get an extended `PATH`, so `cargo`, `zig`, and `java` resolve even when the app was started from Finder. Kotlin also gets `JAVA_HOME`, preferring JDK 21, then 17, then any JDK found in mise or `/Library/Java`. A Rust toolchain binary also pins `RUSTUP_TOOLCHAIN`.

## Install the language servers

Install whichever servers you need. CrossKit never installs anything itself.

```sh
# Rust
rustup component add rust-analyzer

# Zig: zls must match your Zig version (check with `zig version`)
mise install zls@0.17          # or download from https://github.com/zigtools/zls/releases

# Kotlin (needs a JDK; 17 or 21 recommended)
mise install github:fwcd/kotlin-language-server@latest
# or unzip server.zip from https://github.com/fwcd/kotlin-language-server/releases
```

If a server is installed somewhere unusual, use **Choose…** in settings to point at it.

## Build

You need Xcode 16 or later (tested with Xcode 27.2 on macOS 27). The project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen), pinned in `.mise.toml`. The generated `CrossKit.xcodeproj` is committed, so you only need XcodeGen when you change `project.yml`.

```sh
scripts/generate.sh                     # regenerate CrossKit.xcodeproj (optional)
xcodebuild -project CrossKit.xcodeproj -scheme CrossKit -configuration Release \
  -derivedDataPath build/DerivedData build
scripts/test.sh                         # unit + end-to-end tests
```

**Signing.** Xcode refuses App Group entitlements without a provisioning profile, so Xcode's own signing is turned off (`CODE_SIGNING_ALLOWED=NO`). Instead, `scripts/codesign-bundle.sh` signs the finished app inside-out with the right entitlements, ad-hoc (`-`) by default. To sign with your certificate, set an identity:

```sh
CROSSKIT_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" xcodebuild … build
```

## Enable in Xcode

1. Copy `build/DerivedData/Build/Products/Release/CrossKit.app` to `/Applications` and open it once. A menu bar icon appears.
2. Go to **System Settings › General › Login Items & Extensions**, find **Xcode Source Editor** (or **Extensions › Xcode Source Editor**), and enable **CrossKit**. The **Open Extensions Settings…** button in CrossKit opens this pane.
3. Restart Xcode. The commands appear under **Editor › CrossKit**. Bind keys in **Xcode › Settings › Key Bindings** by searching for "CrossKit".
4. The first time you run a command, macOS asks whether CrossKit may control Xcode. Allow it so CrossKit can tell which file is being edited (see Limitations).

## Commands

| Command | LSP request | What happens in the editor |
|---|---|---|
| Complete at Cursor | `textDocument/completion` | Replaces the identifier prefix with the best-ranked match. Snippets become plain text. The caret moves to the end. |
| List Completions | `textDocument/completion` | Inserts up to 40 ranked candidates as comment lines above the cursor. |
| Go to Definition | `textDocument/definition` | In the same file, selects the definition. In another file, Xcode opens it at the right line (`xed --line`) and a comment shows the location. |
| Find References | `textDocument/references` | Inserts a comment block listing `path:line:col` with a preview for each reference. |
| Show Hover Info | `textDocument/hover` | Inserts the hover text (signature and docs) as comments above the cursor. |
| Show Diagnostics | pushed `publishDiagnostics` (or pull `textDocument/diagnostic`) | Inserts `// [CrossKit] error: …` above each affected line. |
| Show Test Markers | – | Inserts `// [CrossKit] ▶ test …` above every test found in the file. |
| Run Tests in File | – | Runs every test in the file, shows a pass/fail summary alert, and puts a `✓ passed` / `✗ failed — reason` marker above each test. |
| Run Test at Cursor | – | Runs only the test that encloses the cursor. |
| Debug File at Cursor | – | Builds the program and debugs it with a breakpoint on the cursor line. |
| Debug Test at Cursor | – | Builds and debugs only the test that encloses the cursor. |
| Clear CrossKit Annotations | – | Removes every `// [CrossKit]` line. |
| Open CrossKit Settings | – | Brings up the host app. |

Annotation lines are ordinary `//` comments in all three languages and always start with `// [CrossKit]`, so you can remove them with one command. Undo works as usual.

## Running tests

| Language | Runners (auto-detect picks the first that applies) | Test discovery |
|---|---|---|
| Zig | `zig build test` when the project has `build.zig`, otherwise `zig test <file>` (with `--test-filter` for one test) | `test "name" { … }`, `test name { … }`, and unnamed `test { … }` blocks |
| Rust | `cargo nextest run` when cargo-nextest is installed, otherwise `cargo test` | `#[test]`, `#[tokio::test]`, and similar attributes inside nested `mod`s; when rust-analyzer is available, its `experimental/runnables` supply the exact test paths and cargo arguments |
| Kotlin | `./gradlew test` when the project has a wrapper, otherwise `gradle test`; filtered with `--tests` | `@Test`, `@ParameterizedTest`, `@RepeatedTest`, and `@TestFactory` functions, including `@Nested` inner classes |

Every run also appears in the host app's **Test Results** window: the command, working directory, duration, full output, and a table of tests with status, time, failure output, and a `file:line` button that opens the test in Xcode. Gradle results come from the JUnit XML reports in `build/test-results/test`. If a runner or toolchain is missing, the alert says what to install or which setting to change. Tests run against the saved file, and you get a warning if the buffer has unsaved changes. Runs time out after the configured test timeout (15 minutes by default); the whole process group is then stopped.

## Debugging

**Debug File at Cursor** and **Debug Test at Cursor** build the program (or the single test) and start a debugger with a breakpoint on the cursor line:

| Language | Build | Debugger (auto-detect first) |
|---|---|---|
| Zig | `zig build-exe` / `zig build install`; tests via `zig test --test-filter … --test-no-exec` | lldb-dap (managed by CrossKit, Debugger window), lldb in Terminal, or CodeLLDB |
| Rust | `cargo build` / `cargo test --no-run`, executable taken from Cargo's JSON output | the same |
| Kotlin | Gradle compiles and reports the runtime classpath; the JVM starts with a JDWP agent (`suspend=y`); tests run via Gradle with the agent in the test JVM | jdb in Terminal (already attached, breakpoint set), or wait for an IDE to attach |

The host app's **Debugger** window shows sessions with Continue / Step Over / Step Into / Step Out / Pause / Stop, the call stack (click to open the line in Xcode), local variables, and program output. Debuggers are auto-detected from Xcode, the Command Line Tools, Homebrew LLVM, and VS Code/Cursor extensions (CodeLLDB), and can be overridden per language. Each project gets an auto-saved **launch configuration** (program or main class, arguments, environment, working directory, test binary arguments), editable in the settings window. Stopping a session, a program exit, or quitting CrossKit leaves no processes behind.

See [docs/GUIDE.md](docs/GUIDE.md) for the detailed user guide.

## Limitations

These are XcodeKit constraints and the workarounds CrossKit uses:

* **No custom UI inside the editor.** Extensions can only run menu commands that edit the buffer and selection. There is no completion pop-up, no squiggles, no hover tooltip, and no live diagnostics; every feature runs on demand. Extra information is inserted as removable comment lines, and messages appear as Xcode alerts, because XcodeKit can only show text as an error.
* **Xcode does not tell extensions the file path.** The host asks Xcode through Apple Events which source documents are open and picks the one whose contents match the buffer. If that fails, for example because Automation permission was denied, the buffer goes into a scratch project in `~/Library/Caches/CrossKit/Scratch`. Single-file features still work, but cross-file results refer to the scratch project.
* **Columns.** LSP positions use UTF-16 code units, the same as XcodeKit's. If you indent with tabs, Xcode may report columns with tabs expanded, which can shift the column slightly.
* **One request at a time.** The bridge handles requests sequentially, so a slow Kotlin request delays the next command.
* **Kotlin without a build file** (a loose `.kt` file) has no stdlib classpath, so `println` and similar are reported as unresolved. In Gradle or Maven projects, kotlin-language-server resolves the classpath with Gradle or Maven, which may use the network on their side. CrossKit itself never does.
* **Cold start.** The first request per language waits for the server to start; Kotlin takes the longest. Empty results during the first minute are retried briefly while the server indexes.
* **Signing.** Ad-hoc signed builds are meant for local use. For distribution, sign with a Developer ID, ideally with a provisioning profile for the App Group, and notarize.
* **Not covered by automated tests.** The XcodeKit glue (`SourceEditorCommand`) can only run inside Xcode. Everything below it, from the editor command engine through the bridge, server manager, and real servers, is covered by tests.

## Tests

```sh
scripts/test.sh
```

* **Unit tests:**
  * LSP/JSON-RPC framing and codec: partial chunks, byte-vs-character lengths, header errors, and request/response/notification encoding.
  * LSP result conversion: Location, LocationLink, CompletionList, snippets, and hover shapes.
  * The editor command engine.
  * Settings persistence.
  * Auto-detection against a fake home directory.
  * The CFMessagePort bridge.
  * A fake Python language server that crashes on purpose, to check initialization, automatic restart with backoff, feature toggles, and that no processes are left behind.
* **End-to-end tests** (`EndToEndTests`), one per language:
  * Each test auto-detects the real server, or skips with an install hint if it is missing.
  * It creates a temporary project (a Cargo crate, a `build.zig` project, or a `.kt` file).
  * It drives the extension's layer (`EditorCommandEngine` → `BridgeClient` → `BridgeServer` → `BridgeHandler` → `ServerManager` → server) and checks startup and initialization, diagnostics for a seeded syntax error, completion of a partial identifier, go to definition, and hover.
  * It then shuts the server down cleanly and checks that the process group is gone.
* **Test-running unit tests:** test discovery for each language, output parsers (`zig test`, `zig build test`, libtest, nextest, JUnit XML, Gradle console), runner selection and command construction against a fake toolchain, missing-tool messages, and editor test markers.
* **Debugging unit tests:** debugger detection against a fake toolchain, launch-plan generation for every language and target, launch-configuration auto-save and overrides, argument/environment parsing, lldb command generation, Cargo artifact parsing, Kotlin class resolution, and unsaved-annotation line mapping.
* **Debugging end-to-end tests** (`DebugEndToEndTests`): Zig and Rust debug a program and a single test through lldb-dap, check that the breakpoint is hit at the right line with the right local variables, run to a clean exit, and check that no adapter or debuggee process is left. A Zig test also runs the generated lldb Terminal script in batch mode. Two Kotlin tests (a program, and a JUnit test via Gradle) start the JVM with JDWP, attach jdb exactly like the Terminal script, hit the breakpoint, read the locals, and exit cleanly.
* **Test-running end-to-end tests** (`TestRunEndToEndTests`), one per language: a temporary project with one passing and one failing test is run through the bridge with **Run Tests in File** and **Run Test at Cursor**, checking statuses, failure output, `file:line` links, and markers. Each test skips if its toolchain is missing. The Kotlin test passes `--offline` when JUnit is already in the Gradle cache.

## Layout

```
project.yml                      XcodeGen spec (source of truth for CrossKit.xcodeproj)
Sources/CrossKitCore/            shared framework: framing, JSON-RPC, LSP client, process mgmt,
                                 server manager, settings, auto-detection, bridge, editor engine
Sources/CrossKitCore/Testing/    test discovery, runners, result parsers
Sources/CrossKitCore/Debugging/  debugger detection, launch planning, DAP client, debug sessions
Sources/CrossKitApp/             host app: settings, Test Results and Debugger windows, menu bar, Xcode lookup
docs/GUIDE.md                    detailed user guide
Sources/CrossKitExtension/       XcodeKit extension (commands → bridge → buffer edits)
Tests/CrossKitCoreTests/         unit + end-to-end tests
scripts/                         generate.sh, test.sh, codesign-bundle.sh
```
