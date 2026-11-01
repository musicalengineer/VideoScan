// tools/html_to_pdf.swift — render a local HTML file to PDF with WebKit (no Chrome, no installs).
//   swift tools/html_to_pdf.swift <in.html> <out-prefix> [width]
// Writes one PDF per element with class "page" (shown one at a time, full height), named
// <out-prefix>-1.pdf, -2.pdf …; the caller merges them (tools/data_organization.py uses pypdf).
// Used for the data-organization diagram (Rick, 2026-10-31): page 1 the blobs, page 2 every table.
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: swift html_to_pdf.swift <in.html> <out-prefix> [width]\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: args[1])
let prefix = args[2]
let width = args.count > 3 ? Double(args[3]) ?? 1300 : 1300

final class Driver: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var pages: [String] = []
    var index = 0
    init(webView: WKWebView) { self.webView = webView }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("[...document.querySelectorAll('.page')].map(p => p.id)") { value, _ in
            self.pages = (value as? [String]) ?? []
            if self.pages.isEmpty { self.pages = [""] }
            self.next()
        }
    }

    func next() {
        guard index < pages.count else { print("done"); exit(0) }
        let id = pages[index]
        let show = id.isEmpty ? "1" :
            "document.querySelectorAll('.page').forEach(p => p.style.display = p.id === '\(id)' ? 'block' : 'none');" +
            "document.querySelectorAll('.tabs').forEach(t => t.style.display = 'none');" +
            "document.querySelectorAll('header').forEach(h => h.style.position = 'static');" +
            "document.body.style.background = '#0d1117'; document.documentElement.scrollTop = 0; document.body.scrollHeight"
        webView.evaluateJavaScript(show) { value, _ in
            let height = max(600.0, ((value as? NSNumber)?.doubleValue ?? 1600) + 40)
            self.webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let config = WKPDFConfiguration()
                config.rect = NSRect(x: 0, y: 0, width: width, height: height)
                self.webView.createPDF(configuration: config) { result in
                    switch result {
                    case .success(let data):
                        let url = URL(fileURLWithPath: "\(prefix)-\(self.index + 1).pdf")
                        try? data.write(to: url)
                        print("wrote \(url.path) (\(Int(height)) px)")
                    case .failure(let error):
                        FileHandle.standardError.write(Data("pdf failed: \(error)\n".utf8))
                    }
                    self.index += 1
                    self.next()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("load failed: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1600), configuration: WKWebViewConfiguration())
let driver = Driver(webView: webView)
webView.navigationDelegate = driver
let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = webView
webView.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
    FileHandle.standardError.write(Data("timed out\n".utf8))
    exit(3)
}
app.run()
