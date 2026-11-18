import AppKit

/// One promise per dragged row. The pasteboard retains the provider, while
/// NSFilePromiseProvider.delegate is weak, so the provider owns its writer.
final class DiscFilePromise: NSFilePromiseProvider {
    private final class Writer: NSObject, NSFilePromiseProviderDelegate {
        let name: String
        let export: (URL, @escaping (Error?) -> Void) -> Void

        init(name: String, export: @escaping (URL, @escaping (Error?) -> Void) -> Void) {
            self.name = name
            self.export = export
        }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

        func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                 completionHandler: @escaping (Error?) -> Void) {
            export(url, completionHandler)
        }
    }

    init(name: String, fileType: String, export: @escaping (URL, @escaping (Error?) -> Void) -> Void) {
        let writer = Writer(name: name, export: export)
        super.init()
        self.fileType = fileType
        self.userInfo = writer
        self.delegate = writer
    }
}
