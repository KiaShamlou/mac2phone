import Foundation

/// The whole point of this tool is that the Mac's screen is unreadable,
/// so status has to be available by ear.
enum Speech {
    static var enabled = true

    static func say(_ text: String, rate: Int = 190) {
        guard enabled else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        task.arguments = ["-r", String(rate), text]
        try? task.run()
    }

    /// "172.20.10.2" -> "1 7 2 dot 2 0 dot 1 0 dot 2" so it is actually intelligible.
    static func spell(ip: String) -> String {
        ip.map { ch -> String in
            ch == "." ? " dot " : "\(ch) "
        }.joined()
    }
}
