import Core
import SwiftUI
import UIKit

/// The Yap keyboard: a microphone key and just enough else (space, delete,
/// return, next keyboard) to fix a word without switching away.
///
/// It records nothing itself. iOS gives keyboards no microphone, so it asks
/// the Yap app to, over `Bridge`, and inserts what comes back.
final class KeyboardViewController: UIInputViewController {
    private lazy var model = KeyboardModel(controller: self)

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        let height = view.heightAnchor.constraint(equalToConstant: 260)
        // Below required, so the system's own constraints win while it
        // animates the keyboard in, instead of logging a conflict.
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.appear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappear()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.returnTitle = Self.title(for: textDocumentProxy.returnKeyType)
    }

    /// Inserts dictated text as if typed, with a space before it when it
    /// would otherwise run into the word before.
    func insert(_ text: String) {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let needsSpace = before.last.map { !$0.isWhitespace } ?? false
        textDocumentProxy.insertText(needsSpace ? " " + text : text)
    }

    private static func title(for type: UIReturnKeyType?) -> String {
        switch type {
        case .go: "go"
        case .google, .search, .yahoo: "search"
        case .join: "join"
        case .next: "next"
        case .route: "route"
        case .send: "send"
        case .done: "done"
        case .continue: "continue"
        default: "return"
        }
    }
}
