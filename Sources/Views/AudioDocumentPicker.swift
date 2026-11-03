import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AudioPickerMode: String, Identifiable {
    case files, folder
    var id: String { rawValue }
}

struct AudioDocumentPicker: UIViewControllerRepresentable {
    let mode: AudioPickerMode
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let audioTypes = [UTType.audio, UTType(filenameExtension: "flac") ?? .audio]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: mode == .folder ? [.folder] : audioTypes, asCopy: false)
        picker.allowsMultipleSelection = mode == .files
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}
