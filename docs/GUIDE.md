# CrossKit User Guide

This guide explains how to install, configure, and use CrossKit day to day: language features, running tests, and debugging Kotlin, Zig, and Rust from Xcode. For architecture and build details, see the [README](../README.md).

## Contents

1. [What CrossKit is](#1-what-crosskit-is)
2. [Requirements](#2-requirements)
3. [Installation](#3-installation)
4. [The host app](#4-the-host-app)
5. [Settings reference](#5-settings-reference)
6. [Editor commands](#6-editor-commands)
7. [Language features](#7-language-features)
8. [Running tests](#8-running-tests)
9. [Debugging](#9-debugging)
10. [Launch configurations](#10-launch-configurations)
11. [Annotations and markers](#11-annotations-and-markers)
12. [Where CrossKit keeps things](#12-where-crosskit-keeps-things)
13. [Troubleshooting](#13-troubleshooting)
14. [Known limitations](#14-known-limitations)

---

## 1. What CrossKit is

CrossKit has two parts:

* **CrossKit.app**, the host app. It lives in the menu bar, owns the settings window, and does all the real work: it starts language servers, test runners, and debuggers.
* **CrossKit Extension**, an Xcode Source Editor Extension. It adds the **Editor › CrossKit** menu. Each command sends the current buffer and cursor to the host app and applies the result to the editor.

Xcode extensions cannot draw custom UI in the editor. So CrossKit shows results in three ways:

* **Editor edits.** For example, completion inserts text and go to definition moves the selection.
* **Comment lines** starting with `// [CrossKit]`, such as diagnostics, hover text, and test results. One command removes them all.
* **An alert**, used for short messages such as a test summary or "No definition found". XcodeKit can only show text this way.

Longer output, such as test results and debug sessions, goes to the host app's **Test Results** and **Debugger** windows.

## 2. Requirements

* macOS 14 or later, and Xcode 16 or later (tested with Xcode 27.2).
* For each language you want to use:

| Language | Language server | Tests | Debugging |
|---|---|---|---|
| Kotlin | `kotlin-language-server` + a JDK (17 or 21 recommended) | Gradle (`./gradlew` or `gradle`) with JUnit 5 | A JDK (`java`, `jdb`) + Gradle |
| Zig | `zls` matching your Zig version | `zig` | `zig` + `lldb-dap` or `lldb` (from Xcode or the Command Line Tools) |
| Rust | `rust-analyzer` | `cargo` (optionally `cargo-nextest`) | `cargo` + `lldb-dap` or `lldb`, or CodeLLDB |

CrossKit never installs anything and makes no network calls. Gradle and Cargo may download dependencies on their own, unless you pass `--offline` (see [Extra test arguments](#test-settings)).

Typical installs:

```sh
rustup component add rust-analyzer          # Rust language server
cargo install cargo-nextest                 # optional, faster Rust test runner
mise use -g zig@latest && mise install zls@<your zig version>
mise install github:fwcd/kotlin-language-server@latest
mise use -g java@temurin-21 gradle@latest
xcode-select --install                      # lldb / lldb-dap if Xcode is not installed
```

## 3. Installation

1. Build CrossKit (see the README) and copy `CrossKit.app` to `/Applications`.
2. Open CrossKit.app once. A `</>` icon appears in the menu bar.
3. Open **System Settings › General › Login Items & Extensions › Xcode Source Editor** and turn on **CrossKit**. The **Open Extensions Settings…** button in CrossKit's settings window opens that pane.
4. Restart Xcode. The commands appear under **Editor › CrossKit**.
5. The first time you run a command, macOS asks whether CrossKit may control Xcode. Click **Allow**. CrossKit uses this to find the path of the file you are editing, which Xcode does not tell extensions. Without it, language features still work on a scratch copy, but tests and debugging need the real path.
6. Optional: bind keys in **Xcode › Settings › Key Bindings** by searching for "CrossKit". Suggested bindings:

| Command | Suggested key |
|---|---|
| Complete at Cursor | ⌃Space |
| Go to Definition | ⌃⌘J |
| Show Diagnostics | ⌃⌘D |
| Run Test at Cursor | ⌃⌘U |
| Debug File at Cursor | ⌃⌘R |

If the host app is not running when you use a command, the extension starts it in the background.

## 4. The host app

**Menu bar menu**

* The status of each language server, for example `Rust: running`.
* **Debugger…** opens the Debugger window.
* **Test Results…** opens the Test Results window.
* **Settings…** opens the settings window.
* **Quit CrossKit** stops every language server, test, and debug session, then quits.

**Settings window.** Everything is saved as soon as you change it; there is no Save button. See [Settings reference](#5-settings-reference).

**Test Results window**

* Lists the last 50 test runs, newest first.
* For a selected run, it shows the command, working directory, duration, exit status, and a table of tests with status, time, and failure output.
* Each test has a `file:line` button that opens the test in Xcode.
* The full runner output is shown underneath.

**Debugger window**

* Lists debug sessions.
* For a session controlled by CrossKit (lldb-dap or CodeLLDB), it has **Continue**, **Step Over**, **Step Into**, **Step Out**, **Pause**, and **Stop** buttons, plus the call stack, the local variables of the top frame, and the program's output.
* Click a stack frame to open that line in Xcode.
* The window comes to the front when a session starts or pauses at a breakpoint.

## 5. Settings reference

### General

| Setting | Default | Meaning |
|---|---|---|
| Bridge | – | Shows whether the host is listening for the extension. If it shows an error, quit and reopen CrossKit. |
| Stop idle servers after | 15 min | A language server unused for this long is shut down. Set it to `never` to keep servers running. |
| Test timeout | 15 min | A test run, or a debug build, that takes longer is stopped together with all of its child processes. |
| Re-detect Servers | – | Looks for servers, test tools, and debuggers again, for example after you install something. |

### Per language (Kotlin, Zig, Rust)

| Setting | Meaning |
|---|---|
| Enabled | Turns the language off entirely. Commands then say the language is disabled. |
| Server | The language server binary. It is auto-detected unless you pick one from **Detected (n)** or with **Choose…**. **Use Auto-detect** returns to automatic detection. |
| Features | Checkboxes for Completion, Go to Definition, Find References, Diagnostics, Hover, Run Tests, and Debugging. A command whose feature is off answers "… is turned off". |
| Status | Live server state (running with pid and workspace, starting, restarting, stopped, error, or not found), the restart count, and the last error with the end of the server's stderr. Use **Restart** and **Stop** to control the server. |

<a id="test-settings"></a>**Test settings** (per language)

| Setting | Meaning |
|---|---|
| Test runner | **Auto-detect**, or force a runner: Zig `zig build test` / `zig test`; Rust `cargo test` / `cargo nextest`; Kotlin `Gradle wrapper (./gradlew test)` / `Gradle (gradle test)`. |
| Test tools | The detected `zig`, `cargo`, `cargo-nextest`, `gradle`, and `java`, or "not found". Use **Choose…** to set a custom binary (it replaces zig, cargo, or gradle), and **Use Auto-detect** to undo that. |
| Extra test arguments | Appended to every test command, for example `--offline` for Gradle or `--release` for Cargo. For Kotlin, they are also passed to the Gradle calls used for debugging. |

**Debug settings** (per language)

| Setting | Meaning |
|---|---|
| Debugger | **Auto-detect**, or one of: Zig/Rust **lldb-dap (CrossKit Debugger window)**, **lldb in Terminal**, **CodeLLDB (CrossKit Debugger window)**; Kotlin **JDWP + jdb in Terminal**, **JDWP, wait for IDE to attach**. Auto-detect picks lldb-dap when it is installed (otherwise lldb in Terminal) for Zig and Rust, and jdb for Kotlin. |
| Debugger tools | The detected `lldb-dap`, `lldb`, and `codelldb` (Zig/Rust), or `java` and `jdb` (Kotlin). **Choose …** sets a custom binary for the selected debugger. |
| JDWP port (Kotlin) | The port the debugged JVM listens on. The default is `5005`; `0` picks a free port each time. |

**Launch Configurations.** One entry per project you have debugged. See [Launch configurations](#10-launch-configurations).

### Auto-detection

Servers, test tools, and debuggers are searched for in this order:

1. Tool-specific locations:
   * Rust: `~/.rustup/toolchains/*/bin` for rust-analyzer and cargo.
   * lldb and lldb-dap: the selected Xcode (`xcode-select -p`), `/Applications/Xcode.app`, the Command Line Tools, then Homebrew LLVM.
   * CodeLLDB: `~/.vscode/extensions/vadimcn.vscode-lldb-*/adapter/codelldb`, plus the same path under `~/.cursor`, `~/.vscode-insiders`, and `~/.windsurf`.
2. mise installs (newest version first). `MISE_DATA_DIR` is respected.
3. `~/.cargo/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, and SDKMAN.
4. mise shims, but only if the tool is really installed.
5. `PATH`.

The JDK comes from `JAVA_HOME`, then mise (21 is preferred, then 17), then `/Library/Java/JavaVirtualMachines`.

## 6. Editor commands

All commands are under **Editor › CrossKit**.

| Command | What it does |
|---|---|
| Complete at Cursor | Replaces the identifier before the cursor with the best completion. |
| List Completions | Inserts up to 40 ranked candidates as comment lines above the cursor. |
| Go to Definition | Selects the definition. If it is in another file, Xcode opens that file at the line. |
| Find References | Inserts a comment block listing every reference as `path:line:col` with a preview. |
| Show Hover Info | Inserts the type, signature, and documentation of the symbol under the cursor as comments. |
| Show Diagnostics | Inserts `// [CrossKit] error: …` above each line with an error or warning. |
| Clear CrossKit Annotations | Removes every `// [CrossKit]` line in the file. |
| Show Test Markers | Inserts `// [CrossKit] ▶ test <name>` above every test in the file. |
| Run Tests in File | Runs all tests in the file, marks each one `✓` or `✗`, and shows a summary. |
| Run Test at Cursor | Runs only the test that contains the cursor. |
| Debug File at Cursor | Builds the program and starts the debugger, with a breakpoint on the cursor line. |
| Debug Test at Cursor | Builds the test that contains the cursor and debugs only that test, with a breakpoint on the cursor line. |
| Open CrossKit Settings | Brings up the host app. |

Every edit is a normal editor change, so **Undo** reverts it.

## 7. Language features

* **Servers start lazily.** The first command for a language starts its server for the workspace root.
  * The root is the nearest folder with `Cargo.toml`/`rust-project.json` (Rust), `build.zig`/`zls.json` (Zig), or `settings.gradle(.kts)`/`build.gradle(.kts)`/`pom.xml` (Kotlin).
  * If there is none, the nearest `.git` folder is used, and otherwise the file's folder.
  * Each language and root pair has its own server.
* **Warm-up.** Servers need time to index, Kotlin especially (up to a minute). Empty results in the first minute are retried automatically.
* **Crash handling.**
  * A crashed server restarts after 1, 2, 4, 8, then 16 seconds.
  * After 5 crashes within 5 minutes it stays stopped, and the error appears under Status.
  * Click **Restart** to try again.
* **Completion** inserts plain text. Snippet placeholders such as `${1:arg}` are removed.
* **Diagnostics** are whatever the server has published for the current buffer content. Run the command again after editing.

## 8. Running tests

### Quick start

1. Open a test file in Xcode and **save it**, because tests run against the saved file.
2. Choose **Editor › CrossKit › Run Tests in File**, or put the cursor inside a test and choose **Run Test at Cursor**.
3. A summary alert appears, for example:
   ```
   ✗ Rust · cargo nextest: 1 passed, 1 failed in 1.7s
   ✗ tests::fails_on_purpose:16
   Details: CrossKit › Test Results
   ```
4. Each test gets a marker above it (above its `#[test]` or `@Test` line):
   ```rust
   // [CrossKit] ✓ passed 0.010s
   #[test]
   fn adds() { … }

   // [CrossKit] ✗ failed — assertion `left == right` failed: math is hard
   #[test]
   fn fails_on_purpose() { … }
   ```
   Running again replaces the old markers. **Clear CrossKit Annotations** removes them.
5. Open **CrossKit › Test Results** for the full output, timings, and clickable `file:line` links.

### How tests are found

| Language | Recognized tests |
|---|---|
| Zig | `test "name" { … }`, `test identifier { … }`, and unnamed `test { … }` blocks. |
| Rust | Functions with `#[test]`, `#[tokio::test]`, `#[rstest]`, `#[test_case]`, `#[wasm_bindgen_test]`, or `#[quickcheck]`, inside any nesting of inline `mod`s. The module path comes from the file's location in the crate (`src/a/b.rs` → `a::b::…`). If rust-analyzer is enabled and running, its `experimental/runnables` result is used instead, which gives exact test paths and Cargo arguments. |
| Kotlin | Functions annotated `@Test`, `@ParameterizedTest`, `@RepeatedTest`, `@TestFactory`, or `@TestTemplate` (JUnit 5 or `kotlin.test`), including `@Nested` inner classes. Test ids use the package and class: `demo.CalcTest.adds`, `demo.CalcTest$Inner.case`. |

"At cursor" means the nearest test that starts at or above the cursor line.

### Which runner runs

| Language | Auto-detect picks | Command for the whole file | Command for one test |
|---|---|---|---|
| Zig | `zig build test` if the project has `build.zig` | `zig build test --summary all` (runs the project's test step) | Same as the whole file. The project's test step decides what runs, and results are mapped to this file's tests. |
| Zig | `zig test` for a loose file | `zig test <file>` | `zig test <file> --test-filter "<name>"` |
| Rust | `cargo nextest` if `cargo-nextest` is installed | `cargo nextest run --no-fail-fast <target> <module>::` | `cargo nextest run <target> -E 'test(=<path>)'` |
| Rust | otherwise `cargo test` | `cargo test <target> -- <module>::` | `cargo test <target> -- <path> --exact` |
| Kotlin | `./gradlew test` if the project has an executable wrapper | `gradlew :module:test --tests <Class>` | `gradlew :module:test --tests <Class.method>` |
| Kotlin | otherwise `gradle test` | same, with `gradle` | same, with `gradle` |

* `<target>` is chosen from the file's location: `tests/<name>.rs` → `--test <name>`, `src/bin/<name>.rs` → `--bin <name>`, `src/main.rs` (or any file of a crate without `src/lib.rs`) → `--bins`, other files → `--lib`.
* Gradle results are read from the JUnit XML reports in `<module>/build/test-results/test`. Only reports written during this run are used.
* Commands run in the project root.
  * `PATH` is extended with the toolchain's folder, `~/.cargo/bin`, mise shims, and Homebrew.
  * Kotlin also gets `JAVA_HOME`.
  * Colors are turned off.
* Gradle uses its normal daemon for test runs, which makes repeated runs faster.

### When something is missing

CrossKit says what to install or which setting to change. For example:

* `zig was not found. Install Zig (e.g. mise use -g zig@latest) or choose the zig binary in CrossKit settings.`
* `cargo-nextest was not found. Install it (cargo install cargo-nextest …) or pick "cargo test" in CrossKit settings.`
* `No executable ./gradlew in /path. Choose "Gradle" as the runner or add the wrapper.`
* `No tests found in main.zig.` / `No test function at or above the cursor.`
* `Save the file inside a project before running tests (CrossKit could not determine its path).`

If the buffer has unsaved changes, the summary warns you: "tests ran against the saved file".

## 9. Debugging

### Quick start (Zig or Rust)

1. Save the file. Put the cursor on the line where you want to stop.
2. Choose **Editor › CrossKit › Debug File at Cursor**. To debug a single test, put the cursor inside it and choose **Debug Test at Cursor**.
3. CrossKit builds the program. The alert confirms the start, for example: `▶ Debugging main.zig with lldb-dap; breakpoint at main.zig:5. Controls are in CrossKit › Debugger.`
4. The **Debugger** window opens. When the breakpoint is hit, you see the call stack and local variables. Use **Continue**, **Step Over**, **Step Into**, **Step Out**, **Pause**, and **Stop**.
5. When the program exits, the session shows its exit code. **Stop** ends the session at any time and kills the program and the debugger.

With **lldb in Terminal**, a Terminal window opens running `lldb`. The program is already launched with your breakpoint set, and you continue with normal lldb commands (`continue`, `next`, `step`, `finish`, `frame variable`, `bt`, `breakpoint set …`).

### Quick start (Kotlin)

1. Open a file in a Gradle project. Put the cursor on a line in `main` (or anything `main` calls) and choose **Debug File at Cursor**. For a JUnit test, put the cursor in the test and choose **Debug Test at Cursor**.
2. CrossKit compiles the project with Gradle and starts the JVM with a JDWP agent that **waits for a debugger** (`suspend=y`) on `127.0.0.1:<port>`.
3. What happens next depends on the debugger setting:
   * **JDWP + jdb in Terminal** (default): a Terminal window opens with `jdb` attached. The breakpoint (`stop at demo.MainKt:5`) is already set and the program is running. Use jdb commands such as `locals`, `print x`, `where`, `next`, `step`, `cont`, and `clear`.
   * **JDWP, wait for IDE to attach**: attach from IntelliJ IDEA (**Run › Edit Configurations › + › Remote JVM Debug**, host `127.0.0.1`, the port shown) or from VS Code. Then set breakpoints there.
4. The Debugger window shows the JDWP address, a **Copy** button for the `jdb -attach` command, the program's output, and **Stop**.

### What gets built and launched

| Language | Debug File at Cursor | Debug Test at Cursor |
|---|---|---|
| Zig, loose file | `zig build-exe <file> -femit-bin=<cache>/<name>`, then that binary | `zig test <file> --test-filter "<name>" --test-no-exec -femit-bin=<cache>/<name>-test`, then that test binary |
| Zig, `build.zig` project | `zig build install` (when **Build before launching** is on), then the executable in `zig-out/bin` named like the project folder, or like the file, or the first one found | same as a loose file (compiles only this file's tests) |
| Rust | `cargo build --bins` (or `--bin <name>` for `src/bin/<name>.rs`); the executable comes from Cargo's JSON output | `cargo test --no-run <target>`, then the test binary with `<test path> --exact --nocapture --test-threads=1` |
| Kotlin | `gradle :module:crossKitClasspath` (compiles and prints the runtime classpath), then `java -agentlib:jdwp=… -cp <classpath> <MainClass>` | `gradle :module:test --tests <Class.method> --rerun` with the JDWP agent added to the test JVM |

* The file must declare `main` for **Debug File at Cursor**: `pub fn main` in Zig, `fn main` in Rust, top-level `fun main` in Kotlin.
* In a Rust library file of a crate that also has a binary, **Debug File at Cursor** builds and launches the binary and keeps the breakpoint in your library file.
* Kotlin main class: `<package>.<FileName>Kt`, or the name from `@file:JvmName("…")`. The breakpoint class is the innermost `class` or `object` around the cursor, or that file class.
* Kotlin needs Gradle (wrapper or installed). CrossKit adds a small init script (`crosskit-init.gradle` in its cache folder) that provides the classpath task and the test JVM's JDWP option. It does not change your build files.
* Debug builds pass `--no-daemon` and `-Pkotlin.compiler.execution.strategy=in-process` to Gradle, so no Gradle or Kotlin daemon is left running after the session.
* Builds use the **Test timeout** and run in the project root. If a build fails, the alert shows the command and the last 25 lines of output.

### Breakpoints

* The breakpoint goes on the cursor line of the saved file. Paths are resolved fully (for example `/private/tmp/…` rather than `/tmp/…`), so they match the debug info.
* If that line has no code, such as a blank line, a comment, or a Rust tail expression, lldb-dap sessions try the next four lines. The Output pane says where the breakpoint ended up ("resolved" or "pending").
* Lines with several machine locations (for example inside `assert_eq!`) may stop more than once. Press **Continue** again.
* If the buffer differs from the saved file only by `// [CrossKit]` lines, the cursor line is mapped to the saved file automatically. Any other unsaved change gives a warning that lines may not match.

### Choosing a debugger

| Debugger | Controlled by | Good for |
|---|---|---|
| lldb-dap | CrossKit's Debugger window | Quick inspection: stack, locals, and stepping without leaving the Mac UI. |
| lldb in Terminal | You, in Terminal | Everything lldb can do: watchpoints, expressions, conditional breakpoints. |
| CodeLLDB | CrossKit's Debugger window | Rust-aware value formatting. It is started over stdio, which has not been tested with every CodeLLDB version. |
| JDWP + jdb | You, in Terminal | Kotlin/JVM without an IDE. |
| JDWP, wait for IDE | Your IDE | Full Kotlin debugging in IntelliJ IDEA. |

### When something is missing

* `lldb-dap was not found. Install Xcode or the Command Line Tools (xcode-select --install), or choose the binary in CrossKit settings.`
* `codelldb was not found. Install the CodeLLDB extension (vadimcn.vscode-lldb) … or pick lldb-dap.`
* `java was not found. Install a JDK 17 or 21 (e.g. mise use -g java@temurin-21) or choose java in CrossKit settings.`
* `main.zig has no main function. Open the file with main, or use Debug Test at Cursor inside a test.`
* `Debugging Kotlin needs a Gradle project …`
* `Build failed: <command>` followed by the compiler output.

### Cleanup

* Each session runs its debugger, JVM, or Gradle process in its own process group.
* **Stop**, a program exit, or quitting CrossKit ends the session. CrossKit asks the debugger to terminate the program, then kills the process group and any debuggee process that is still alive.
* lldb and jdb sessions in Terminal belong to Terminal. Close them there.

## 10. Launch configurations

The first time you debug a project, CrossKit creates a **launch configuration** for that language and project root and saves it. Edit it in **Settings › Launch Configurations**; changes are saved immediately.

| Field | Meaning |
|---|---|
| Program (Zig/Rust) | Leave empty to let CrossKit build and find the program. If set, CrossKit launches this executable as is, without building. |
| Main class (Kotlin) | Leave empty for the file's class (e.g. `demo.MainKt`). If set, this class is launched instead. |
| Arguments | Command-line arguments for **Debug File at Cursor**, as you would type them in a shell: `--port 8080 "two words"`. |
| Environment | `KEY=VALUE`, one per line. Lines starting with `#` are ignored. Applied to the debugged program. |
| Working directory | Empty means the project root. |
| Test binary arguments | Extra arguments for the test binary in **Debug Test at Cursor**, for example `--include-ignored` (Rust). Not used for Kotlin. |
| Build before launching | For Zig projects with `build.zig`: run `zig build install` first. Loose Zig files, Cargo, and Gradle projects are always built, because the build produces the program path or classpath. |
| Delete | Removes the configuration. A fresh default is created the next time you debug the project. |

Configurations live in CrossKit's shared settings, not in your project, so nothing is added to your repository.

## 11. Annotations and markers

Every line CrossKit inserts is a `//` comment that starts with `// [CrossKit]`. This works in Kotlin, Zig, and Rust.

| Example | Source |
|---|---|
| `// [CrossKit] error: expected expression, found ';' [9:18] (zls)` | Show Diagnostics |
| `// [CrossKit] completions for "comp" (3):` then `// [CrossKit]   compute_answer — fn(i32) -> i32` | List Completions |
| `// [CrossKit] 2 reference(s):` then `// [CrossKit]   src/lib.rs:12:5  let x = compute(1);` | Find References |
| `// [CrossKit] definition:` then `// [CrossKit]   src/util.rs:3:8  pub fn compute(…)` | Go to Definition (other file) |
| `// [CrossKit] ▶ test add works — Editor › CrossKit › Run Test at Cursor` | Show Test Markers |
| `// [CrossKit] ✓ passed 0.010s` / `✗ failed — reason` / `○ skipped` | Run Tests |

* Test markers (`▶ ✓ ✗ ○`) are replaced on every run.
* Other annotations stay until **Clear CrossKit Annotations**.
* Debug commands never edit the buffer.

## 12. Where CrossKit keeps things

| What | Where |
|---|---|
| Settings, server status, launch configurations | `UserDefaults` suite `group.dev.pyrlyn.CrossKit` (App Group shared by the app and the extension) |
| Scratch copies of unsaved buffers | `~/Library/Caches/CrossKit/Scratch` |
| Debug builds of loose files, Gradle init script, session scripts (`lldb-commands`, `.jdbrc`, `CrossKit Debug.command`) | `~/Library/Caches/CrossKit/Debug` |
| Logs | Console.app, process `CrossKit` |

You can delete the cache folders at any time.

## 13. Troubleshooting

| Symptom | What to do |
|---|---|
| The CrossKit menu is missing in Xcode | Enable the extension in System Settings (step 3 of Installation) and restart Xcode. Make sure only one copy of CrossKit.app exists (for example, remove old builds from DerivedData). |
| "CrossKit host app is not reachable" or "did not answer in time" | Open CrossKit.app. If **Bridge** shows an error, quit CrossKit and open it again. A long test run or debug build also blocks other commands until it finishes. |
| Results refer to a `Scratch` folder | Automation permission was denied. Allow it under **System Settings › Privacy & Security › Automation › CrossKit › Xcode**. |
| Server shows **Not found** | Install it (see the hint under Server), or **Choose…** its binary, then click **Re-detect Servers**. |
| Kotlin results are empty at first | kotlin-language-server is still indexing. Wait a minute and try again. |
| zls reports a version mismatch | Install the zls version that matches `zig version`. |
| Gradle downloads or fails offline | Add `--offline` to **Extra test arguments** once dependencies are cached, or let it download once. |
| A breakpoint never hits | Save the file. Make sure the line has code, and check the Output pane for "pending". For `build.zig` projects, make sure the debugged executable is the one that contains the file. |
| Debugger shows no variables | The top frame may be in a system library. Use **Step Out** or **Continue** to a breakpoint in your code. |
| Kotlin JVM "waiting for debugger" forever | Attach with the command shown in the Debugger window, or click **Stop**. If the port is taken, set **JDWP port** to `0`. |

## 14. Known limitations

* **No inline UI.** There are no pop-ups, squiggles, gutter icons, or live updates. Everything runs when you invoke a command (an XcodeKit limitation).
* **Breakpoints only from the cursor.** Each debug command sets one breakpoint, at the cursor line. Add more in lldb or jdb, or in your IDE for JDWP.
* **One request at a time.** The bridge handles requests one after another, so a long test run delays other commands until it finishes.
* **`zig build test`** runs the project's whole test step. Debug Test at Cursor compiles the file with `zig test`, which works when the file's imports resolve without `build.zig` modules.
* **Kotlin debugging** needs Gradle. Maven-only and loose `.kt` files are not supported for debugging or tests.
* **CodeLLDB** support has not been tested in CI. lldb-dap from Xcode is the tested path.
