import AppKit
import AIShortcutsRendering
import Darwin

if CommandLine.arguments.count >= 2,
   CommandLine.arguments[1] == "--pasteboard-snapshot"
{
    guard CommandLine.arguments.count == 3,
          let snapshot = ClipboardSnapshot.capture(
              from: NSPasteboard(
                  name: NSPasteboard.Name(CommandLine.arguments[2])
              )
          ),
          let data = snapshot.encoded()
    else {
        exit(EXIT_FAILURE)
    }
    FileHandle.standardOutput.write(data)
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.run()
