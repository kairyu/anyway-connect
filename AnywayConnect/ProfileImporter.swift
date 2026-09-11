import Foundation

// Detects existing VPN endpoints from installed client profiles.
// Currently supports Cisco AnyConnect / Secure Client profile XMLs, which use:
//   <ServerList><HostEntry><HostName>..</HostName><HostAddress>..</HostAddress>
// (BackupServerList entries are ignored; we take the primary HostAddress.)

struct ImportedEndpoint {
    var label: String
    var host: String
    var sourceProtocol: String  // best guess (anyconnect for Cisco)
}

/// One configuration file found on disk, with the endpoints it contained.
/// Auto-detect reports these individually so the user can pick which one to
/// import, rather than being handed every endpoint from every file at once.
struct DetectedConfig {
    var name: String        // display name, derived from the file name
    var path: String
    var endpoints: [ImportedEndpoint]
}

enum ProfileImporter {
    // Well-known profile locations to scan.
    static let searchPaths: [String] = [
        "/opt/cisco/secureclient/vpn/profile",
        "/opt/cisco/anyconnect/profile",
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Cisco/Cisco Secure Client/VPN/Profile"),
    ]

    /// Scan the well-known client-profile directories, one entry per file that
    /// yielded at least one endpoint.
    static func detectConfigs() -> [DetectedConfig] {
        let fm = FileManager.default
        var found: [DetectedConfig] = []
        for dir in searchPaths {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in items.sorted() where name.lowercased().hasSuffix(".xml") {
                let path = (dir as NSString).appendingPathComponent(name)
                if let cfg = parse(fileAt: path), !cfg.endpoints.isEmpty { found.append(cfg) }
            }
        }
        return found
    }

    /// Parse a single file, whether auto-detected or chosen by the user.
    static func parse(fileAt path: String) -> DetectedConfig? {
        let endpoints = parseCiscoProfile(atPath: path)
        guard !endpoints.isEmpty else { return nil }
        // De-dup by host within the one file.
        var seen = Set<String>()
        let unique = endpoints.filter { seen.insert($0.host).inserted }
        let name = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".xml", with: "", options: .caseInsensitive)
        return DetectedConfig(name: name.isEmpty ? "Imported" : name, path: path, endpoints: unique)
    }

    static func parseCiscoProfile(atPath path: String) -> [ImportedEndpoint] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = CiscoProfileParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.endpoints
    }
}

// Minimal SAX parser for Cisco profiles: collects HostName/HostAddress pairs
// inside each HostEntry, ignoring BackupServerList.
private final class CiscoProfileParser: NSObject, XMLParserDelegate {
    var endpoints: [ImportedEndpoint] = []

    private var currentElement = ""
    private var inHostEntry = false
    private var inBackupList = false
    private var curName = ""
    private var curAddress = ""
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        currentElement = elementName
        buffer = ""
        switch elementName {
        case "HostEntry": inHostEntry = true; curName = ""; curAddress = ""
        case "BackupServerList": inBackupList = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "HostName" where inHostEntry:
            curName = text
        case "HostAddress" where inHostEntry && !inBackupList:
            if curAddress.isEmpty { curAddress = text }  // primary only
        case "BackupServerList":
            inBackupList = false
        case "HostEntry":
            if !curAddress.isEmpty {
                let label = curName.isEmpty ? curAddress : curName
                endpoints.append(ImportedEndpoint(label: label, host: curAddress, sourceProtocol: "anyconnect"))
            }
            inHostEntry = false
        default: break
        }
        buffer = ""
    }
}

// Turn a human label into a short endpoint key (lowercase, alnum).
func makeKey(from label: String, existing: Set<String>) -> String {
    let base = label.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .prefix(2)
        .joined()
    let key = base.isEmpty ? "ep" : String(base.prefix(12))
    var n = 1
    let candidateBase = key
    var candidate = key
    while existing.contains(candidate) {
        n += 1
        candidate = "\(candidateBase)\(n)"
    }
    return candidate
}
