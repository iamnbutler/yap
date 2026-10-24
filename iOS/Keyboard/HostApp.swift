import UIKit

/// Opens a URL from inside a keyboard, which iOS doesn't offer: a keyboard's
/// `extensionContext.open` does nothing, and `UIApplication.open` is marked
/// unavailable in extensions.
///
/// But the keyboard's views do sit in a responder chain that ends at the
/// process's UIApplication, and calling `open(_:options:completionHandler:)`
/// on it works. This is how keyboards that dictate get to their app (Wispr
/// Flow does the same). It is the one fragile piece: if a future iOS breaks
/// it, the keyboard says to open Yap by hand instead.
@MainActor
enum HostApp {
    @discardableResult
    static func open(_ url: URL, from responder: UIResponder) -> Bool {
        var next: UIResponder? = responder
        while let current = next {
            if let application = current as? UIApplication {
                return call(application, url)
            }
            next = current.next
        }
        return false
    }

    /// Through the Objective-C runtime, since Swift won't compile the call in
    /// an extension. `perform(_:with:with:)` can't be used: the method takes
    /// three arguments, and the third (the completion block) would be garbage.
    private static func call(_ application: UIApplication, _ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        guard application.responds(to: selector) else { return false }
        typealias Open = @convention(c) (
            AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
        ) -> Void
        let open = unsafeBitCast(application.method(for: selector), to: Open.self)
        open(application, selector, url as NSURL, NSDictionary(), nil)
        return true
    }
}
