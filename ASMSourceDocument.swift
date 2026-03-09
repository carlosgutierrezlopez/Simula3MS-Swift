import SwiftUI
import UniformTypeIdentifiers

struct ASMSourceDocument: FileDocument {
    static var asmSourceType: UTType { UTType(filenameExtension: "s") ?? .plainText }
    static var readableContentTypes: [UTType] { [asmSourceType, .plainText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            self.text = ""
            return
        }

        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}
