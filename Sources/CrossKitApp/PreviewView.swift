import SwiftUI
import AppKit
import CrossKitCore

/// Compose previews of one Kotlin file, like Xcode's canvas for SwiftUI.
@MainActor
enum PreviewWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if window == nil {
            let hosting = NSHostingController(rootView: PreviewView().environmentObject(model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "CrossKit Preview"
            w.setContentSize(NSSize(width: 760, height: 640))
            w.styleMask.insert([.resizable, .miniaturizable])
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("CrossKitPreview")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PreviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLog = false
    @State private var zoom = 1.0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let result = model.preview {
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if let error = model.previewError {
                                Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                            }
                            if let warning = result.warning {
                                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            }
                            ForEach(result.previews) { rendered in
                                card(rendered, focused: rendered.id == result.focusedID, density: result.density).id(rendered.id)
                            }
                            if showLog {
                                Text(result.log).font(.caption2.monospaced()).textSelection(.enabled)
                            }
                        }
                        .padding(16)
                    }
                    .onAppear { if let id = result.focusedID { proxy.scrollTo(id, anchor: .top) } }
                    .onChange(of: result.id) { _, _ in if let id = result.focusedID { proxy.scrollTo(id, anchor: .top) } }
                }
            } else {
                Text("No preview yet.\nPut the cursor in a @Preview function and use Editor › CrossKit › Show Compose Preview at Cursor.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onReceive(timer) { _ in model.checkPreviewAutoRefresh() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if let result = model.preview {
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.fileName).font(.headline)
                    Text("\(result.target) · \(result.summary)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if model.previewRendering { ProgressView().controlSize(.small) }
            Toggle("Auto-refresh on save", isOn: model.previewAutoRefreshBinding).toggleStyle(.checkbox)
            Picker("Zoom", selection: $zoom) {
                Text("50%").tag(0.5)
                Text("100%").tag(1.0)
                Text("200%").tag(2.0)
            }
            .labelsHidden()
            .fixedSize()
            Toggle("Log", isOn: $showLog).toggleStyle(.button)
            Button("Refresh") { model.refreshPreview() }
                .keyboardShortcut("r")
                .disabled(model.preview == nil || model.previewRendering)
        }
        .padding(10)
    }

    @ViewBuilder
    private func card(_ rendered: RenderedPreview, focused: Bool, density: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(rendered.preview.name).fontWeight(focused ? .semibold : .regular)
                if rendered.pixelWidth > 0 {
                    Text("\(Int(Double(rendered.pixelWidth) / density))×\(Int(Double(rendered.pixelHeight) / density)) dp")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    if let path = model.preview?.filePath { model.openInXcode(file: path, line: rendered.preview.line + 1) }
                } label: {
                    Text("line \(rendered.preview.line + 1)").font(.caption)
                }
                .buttonStyle(.link)
            }
            if let image = model.previewImages[rendered.id] {
                Image(nsImage: image)
                    .interpolation(.high)
                    .resizable()
                    .frame(width: CGFloat(rendered.pixelWidth) / density * zoom, height: CGFloat(rendered.pixelHeight) / density * zoom)
                    .background(checkerboard)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(focused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: focused ? 2 : 1))
            } else {
                Text(rendered.error ?? "Not rendered.")
                    .font(.caption.monospaced())
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(.gray.opacity(0.15)))
                }
            }
        }
    }
}
