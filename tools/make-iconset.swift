import AppKit

// Writes the .iconset that build-app.sh hands to `iconutil -c icns`.
//
// Compiled against the app's own AppIcon.swift rather than carrying its own copy of the
// artwork, so the icon baked into the bundle and the one the running app draws cannot
// drift apart.
//
// Usage: make-iconset <output.iconset>
//
// `@main` rather than top-level code, because Swift only allows statements at the top level
// of a file called main.swift, and a generator named after its job is worth more than that.
@main
struct MakeIconset {
    static func main() {
        // AppKit needs an application object before it will render symbols.
        _ = NSApplication.shared

        let args = CommandLine.arguments
        guard args.count == 2 else {
            FileHandle.standardError.write(Data("usage: make-iconset <output.iconset>\n".utf8))
            exit(2)
        }

        let out = URL(fileURLWithPath: args[1])
        do {
            try AppIcon.writeIconset(to: out)
            let sizes = AppIcon.iconsetEntries.map { String($0.pixels) }.joined(separator: ", ")
            print("    \(AppIcon.iconsetEntries.count) PNGs at \(sizes)")
        } catch {
            FileHandle.standardError.write(
                Data("make-iconset: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        exit(0)
    }
}
