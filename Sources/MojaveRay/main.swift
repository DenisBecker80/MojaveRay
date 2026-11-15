import AppKit

let application = NSApplication.shared
let applicationDelegate = AppDelegate()

application.setActivationPolicy(AppDelegate.isLoginLaunch ? .accessory : .regular)
application.delegate = applicationDelegate
application.run()
