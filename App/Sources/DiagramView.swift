import LoomKit
import SwiftUI
import WebKit

/// A finished `mermaid` code block drawn as a diagram, with its source a click away.
///
/// The drawing is Loom's own isolated renderer, the web view's frame copied into
/// the app bundle (`App/Resources/Diagram`), so a diagram looks and fails the same
/// in both clients. The source is model-written, so it is handled as the web view
/// handles it: it reaches the renderer only as a message to an `allow-scripts`
/// sandbox with no network, and only a height or a failure comes back. A block
/// that cannot be drawn shows the renderer's words and the source.
struct DiagramBlock: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var phase = Phase.drawing
    @State private var height: CGFloat = DiagramProtocol.minimumHeight
    @State private var showsSource = false

    enum Phase: Equatable {
        case drawing
        case drawn
        case failed(String?)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .failed(let diagnostic) = phase {
                Text("The diagram could not be drawn.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.failure)

                // The renderer's message points at the column with a caret line,
                // so it keeps a fixed-width face.
                if let diagnostic {
                    Text(diagnostic)
                        .font(Theme.code)
                        .foregroundStyle(Theme.failure)
                        .textSelection(.enabled)
                }
                CodeBlockView(code: source, language: "mermaid")
            } else {
                DiagramWebView(
                    source: source,
                    theme: colorScheme == .dark ? "dark" : "default",
                    onRendered: { next in
                        height = next
                        phase = .drawn
                    },
                    onFailed: { phase = .failed($0) }
                )
                .frame(height: height)
                .opacity(phase == .drawn ? 1 : 0)
                .overlay {
                    if phase == .drawing {
                        Text("Drawing the diagram…").font(Theme.caption).foregroundStyle(.tertiary)
                    }
                }
                .accessibilityLabel("Diagram")

                HStack {
                    Spacer()
                    Button(showsSource ? "Hide Source" : "Show Source") { showsSource.toggle() }
                        .buttonStyle(.link)
                        .font(Theme.caption)
                }
                if showsSource {
                    CodeBlockView(code: source, language: "mermaid")
                }
            }
        }
    }
}

/// Serves the five renderer files from the app bundle, each with the content
/// policy the web view sends for it, and refuses every other address.
private final class DiagramFiles: NSObject, WKURLSchemeHandler {
    static let shared = DiagramFiles()

    private struct File {
        let name: String
        let type: String
        let policy: String
    }

    // The frame's policy is the web view's own (`web_view/page.gleam`), so the copied
    // renderer runs under the rules it was built for, with one change: the sandboxed
    // frame has an opaque origin, and WebKit does not match `'self'` to a private
    // scheme from one, so its script source is this scheme's address by name. The
    // host's policy allows only its own script and the one frame.
    private static let framePolicy = "default-src 'none'; script-src loom-diagram://frame; style-src 'unsafe-inline'; img-src 'none'; connect-src 'none'; font-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'; frame-ancestors 'self'; sandbox allow-scripts"
    private static let hostPolicy = "default-src 'none'; script-src loom-diagram://frame; style-src 'unsafe-inline'; img-src 'none'; connect-src 'none'; font-src 'none'; base-uri 'none'; form-action 'none'; frame-src loom-diagram://frame; frame-ancestors 'none'"

    private static let files: [String: File] = [
        "/host.html": File(name: "host.html", type: "text/html", policy: hostPolicy),
        "/host.js": File(name: "host.js", type: "text/javascript", policy: hostPolicy),
        "/ui/assets/mermaid.html": File(name: "mermaid.html", type: "text/html", policy: framePolicy),
        "/ui/assets/mermaid.js": File(name: "mermaid.js", type: "text/javascript", policy: framePolicy),
    ]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "frame",
              let file = Self.files[url.path],
              let location = Bundle.main.url(forResource: file.name, withExtension: nil, subdirectory: "Diagram"),
              let data = try? Data(contentsOf: location),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                  "Content-Type": "\(file.type); charset=utf-8",
                  "Content-Security-Policy": file.policy,
                  "Cache-Control": "no-store",
              ]) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// A web view that never scrolls itself, so the wheel moves the transcript even
/// with the pointer over a diagram.
private final class PassiveWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private struct DiagramWebView: NSViewRepresentable {
    let source: String
    let theme: String
    let onRendered: (CGFloat) -> Void
    let onFailed: (String?) -> Void

    // One store for every diagram, held in memory only, so nothing a renderer does
    // outlives the app or reaches the person's browsing data.
    @MainActor private static let store = WKWebsiteDataStore.nonPersistent()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.store
        configuration.setURLSchemeHandler(DiagramFiles.shared, forURLScheme: DiagramProtocol.scheme)
        configuration.userContentController.add(context.coordinator, name: "diagram")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let view = PassiveWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.allowsBackForwardNavigationGestures = false
        context.coordinator.view = view
        context.coordinator.parent = self
        view.load(URLRequest(url: DiagramProtocol.host))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.send(source: source, theme: theme)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "diagram")
        coordinator.deadline?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var view: WKWebView?
        var parent: DiagramWebView?
        var deadline: Task<Void, Never>?
        private var revision = 0
        private var sent: (source: String, theme: String)?

        // The host page defines render() only once it has loaded, so a request
        // made before then waits here, and only the newest one.
        private var isLoaded = false
        private var waiting: String?

        /// Sends a request when the source or theme changed. Each request has a
        /// new revision, and a reply for any other revision is ignored.
        func send(source: String, theme: String) {
            if let sent, sent.source == source, sent.theme == theme { return }
            sent = (source, theme)
            guard source.utf16.count <= DiagramProtocol.sourceLimit else {
                parent?.onFailed("the diagram is longer than the renderer accepts")
                return
            }
            revision += 1
            guard let request = DiagramProtocol.request(source: source, theme: theme, revision: revision),
                  let literal = try? JSONSerialization.data(withJSONObject: request, options: .fragmentsAllowed),
                  let argument = String(data: literal, encoding: .utf8) else { return }
            if isLoaded {
                view?.evaluateJavaScript("render(\(argument))")
            } else {
                waiting = argument
            }

            let expected = revision
            deadline?.cancel()
            deadline = Task { [weak self] in
                try? await Task.sleep(for: DiagramProtocol.deadline)
                guard let self, !Task.isCancelled, self.revision == expected else { return }
                self.parent?.onFailed("the renderer did not answer")
            }
        }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let text = message.body as? String else { return }
            MainActor.assumeIsolated {
                switch DiagramProtocol.reply(text) {
                case .rendered(let revision, let height) where revision == self.revision:
                    deadline?.cancel()
                    parent?.onRendered(height)
                case .failed(let revision, let diagnostic) where revision == self.revision:
                    deadline?.cancel()
                    parent?.onFailed(diagnostic)
                default:
                    break
                }
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated {
                isLoaded = true
                if let waiting {
                    webView.evaluateJavaScript("render(\(waiting))")
                    self.waiting = nil
                }
            }
        }

        // Only the renderer's own files load. A link inside a diagram, or anything
        // else that would leave the scheme, is refused.
        nonisolated func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            let allowed = action.request.url?.scheme == DiagramProtocol.scheme && action.navigationType == .other
            MainActor.assumeIsolated { decisionHandler(allowed ? .allow : .cancel) }
        }
    }
}

