import SwiftUI
import ReplayKit

struct BroadcastView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pairing: Pairing?
    @State private var notice = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Share this iPhone or iPad", systemImage: "iphone.radiowaves.left.and.right").font(.headline)
                    Text("Paired devices can see your screen and hear supported app audio. iOS broadcasts are view-only. Microphone audio is not sent.")
                    Text("Everything visible after you start broadcasting may be shared, including notifications. Use the system recording indicator to end the broadcast at any time.")
                        .foregroundStyle(.secondary)
                }
                Section("1 · Prepare your broadcast") {
                    Button(pairing == nil ? "Prepare broadcast" : "Replace pairing link") {
                        do { pairing = try BroadcastState.prepare(); notice = "Ready. Replacing a link ends any older broadcast." }
                        catch { notice = error.localizedDescription }
                    }
                    if let pairing {
                        Text("Wi-Fi address: \(pairing.host):\(pairing.port)").font(.caption.monospaced())
                        Button("Copy one-use approval link", systemImage: "doc.on.doc") {
                            guard let grant = try? BroadcastState.grant() else { notice = "Start the system broadcast first, then copy a link."; return }
                            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: grant.link]],
                                options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                            notice = "One-use link copied. Connect within 60 seconds."
                        }
                    }
                }
                if pairing != nil {
                    Section("2 · Start with the system button") {
                        BroadcastPicker().frame(height: 56)
                        Text("Select Mac2Phone Broadcast, then Start Broadcast. Return to Mac2Phone to finish any accepted connection request.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Stop broadcast & revoke link", role: .destructive) {
                        BroadcastState.revoke(); pairing = nil; notice = "Broadcast revoked. Connected viewers will disconnect."
                    }
                }
                if !notice.isEmpty { Text(notice).font(.footnote) }
            }
            .navigationTitle("Broadcast").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { pairing = try? BroadcastState.load() }
        }
    }
}
private struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        picker.preferredExtension = "\(Bundle.main.bundleIdentifier ?? "com.kianoosh.mac2phone").broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
