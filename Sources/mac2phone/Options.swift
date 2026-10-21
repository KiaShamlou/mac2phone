import Foundation

struct Options {
    var port: UInt16 = 8765
    var width: Int = 2560          // 0 = full native resolution
    var fps: Int = 60
    var bitrate: Int = 20_000_000
    var codec: String = "hevc"     // "hevc" or "h264"
    var quality: Double = 0.6      // desktop JPEG only
    var display: Int = 0
    var control: Bool = true
    var cursor: Bool = true
    var speak: Bool = true
    var hotkey: Bool = true
    var list: Bool = false
    var help: Bool = false

    static let usage = """
    mac2phone — mirror and control your Mac from an iPhone or iPad.

    USAGE
      mac2phone [options]

    VIDEO
      --width <px>      Max streamed width, 0 = full native  (default 2560)
      --fps <n>         Frames per second, 1-60              (default 60)
      --bitrate <bps>   Video bitrate                        (default 20000000)
      --codec <name>    hevc | h264                          (default hevc)
      --display <n>     Display index, see --list            (default 0)
      --no-cursor       Do not draw the mouse cursor

    BEHAVIOUR
      --port <n>        TCP port                             (default 8765)
      --no-control      View only, ignore touch and keyboard
      --no-speak        Never announce anything out loud
      --no-hotkey       Do not register global hotkeys
      --quality <0-1>   JPEG quality for desktop viewers (default 0.6)
      --list            List displays and exit
      --help            Show this help

    HOTKEYS
      ctrl+opt+cmd+M    Enable / disable mirroring
      ctrl+opt+cmd+I    Speak the connection address out loud
    """

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        func value() -> String? {
            guard i + 1 < args.count else { return nil }
            i += 1
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--port":    if let v = value(), let n = UInt16(v), n > 0 { o.port = n }
            case "--width":   if let v = value(), let n = Int(v) { o.width = n <= 0 ? 0 : max(320, n) }
            case "--fps":     if let v = value(), let n = Int(v) { o.fps = min(60, max(1, n)) }
            case "--bitrate": if let v = value(), let n = Int(v) { o.bitrate = max(1_000_000, min(80_000_000, n)) }
            case "--codec":   if let v = value() { o.codec = v.lowercased() }
            case "--quality": if let v = value(), let n = Double(v), n.isFinite { o.quality = min(1, max(0.1, n)) }
            case "--display": if let v = value(), let n = Int(v) { o.display = max(0, n) }
            case "--no-control": o.control = false
            case "--no-cursor":  o.cursor = false
            case "--no-speak":   o.speak = false
            case "--no-hotkey":  o.hotkey = false
            case "--list":       o.list = true
            case "--help", "-h": o.help = true
            default: break
            }
            i += 1
        }
        return o
    }
}
