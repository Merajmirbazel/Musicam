import UIKit
import UniformTypeIdentifiers

/// The "Musicam" entry in the iPhone share sheet. It takes the link (or the first link inside shared text) from the app
/// the person is in, hands it to Musicam, and closes. Musicam then adds it (a wishlist entry, or a direct audio download).
final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let icon = UIImageView(image: UIImage(systemName: "music.note.list"))

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        icon.tintColor = UIColor(red: 0.49, green: 0.36, blue: 1.0, alpha: 1)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.text = NSLocalizedString("Opening Musicam…", comment: "")
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor in await handOver() }
    }

    private func handOver() async {
        guard let link = await findLink() else {
            label.text = NSLocalizedString("There is no link here to add.", comment: "")
            try? await Task.sleep(for: .seconds(1.4))
            extensionContext?.cancelRequest(withError: NSError(domain: "Musicam", code: 1))
            return
        }
        var components = URLComponents()
        components.scheme = "musicam"
        components.host = "add"
        components.queryItems = [URLQueryItem(name: "link", value: link.absoluteString)]
        guard let target = components.url, open(target) else {
            // Some iOS versions do not let a share extension open its app: keep the link on the clipboard instead.
            UIPasteboard.general.string = link.absoluteString
            label.text = NSLocalizedString("Link copied. Open Musicam and choose Add from Link.", comment: "")
            try? await Task.sleep(for: .seconds(2.2))
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// The first web link in what was shared: a URL item, or a link inside shared text.
    private func findLink() async -> URL? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier),
               let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                return url
            }
        }
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier),
               let text = value as? String, let url = Self.firstLink(in: text) {
                return url
            }
        }
        for item in items {
            if let text = item.attributedContentText?.string, let url = Self.firstLink(in: text) { return url }
        }
        return nil
    }

    static func firstLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range).compactMap(\.url).first { $0.scheme?.hasPrefix("http") == true }
    }

    /// Share extensions may not call UIApplication.shared; the responder chain still reaches the host's application object.
    private func open(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                typealias OpenFunction = @convention(c) (AnyObject, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any], ((Bool) -> Void)?) -> Void
                let imp = current.method(for: selector)
                let function = unsafeBitCast(imp, to: OpenFunction.self)
                function(current, selector, url, [:], nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}
