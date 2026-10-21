import Foundation
import AppKit

setvbuf(stdout, nil, _IONBF, 0)

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
if options.help {
    print(Options.usage)
    exit(0)
}

// A real (but iconless) app: needed so global hotkeys are delivered and so the
// process gets its own identity in the privacy settings.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let controller = AppController(options: options)
Task { await controller.start() }

// launchd stops us with SIGTERM; put the display back before going away.
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    controller.shutdown()
    exit(0)
}
termSource.resume()
signal(SIGTERM, SIG_IGN)

application.run()
