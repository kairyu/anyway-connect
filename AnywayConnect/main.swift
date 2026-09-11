import AppKit

// The single-instance decision deliberately lives in
// AppDelegate.applicationDidFinishLaunching rather than here.
//
// It used to run at this point, before NSApplication.run(), and that quietly did not
// work: a redundant launch has to *ask* the user what to do now, and NSAlert.runModal()
// cannot present a dialog before AppKit has finished launching — runModal returned
// immediately, the process exited, and the launch once again appeared to do nothing.
// Calling finishLaunching() here to work around that is worse: NSApplication would then
// consider launching done and never deliver applicationDidFinishLaunching to the
// delegate assigned below, so the app would come up with no status item at all.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
