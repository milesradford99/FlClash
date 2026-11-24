import Foundation

struct IspChromeSpaces {
    struct Space: Codable, Equatable {
        let id: String
        let name: String

        var values: [String: String] { ["id": id, "name": name] }
    }

    static let defaultID = "flclash-isp-chrome"
    private static let defaultSpace = Space(id: defaultID, name: "Chrome ISP")
    let support: URL

    private var root: URL { support.appendingPathComponent("Chrome ISP Spaces", isDirectory: true) }
    private var catalog: URL { root.appendingPathComponent("spaces.json") }

    func list() throws -> [Space] {
        let data: Data
        do {
            data = try Data(contentsOf: catalog)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [Self.defaultSpace]
        }
        let spaces = try JSONDecoder().decode([Space].self, from: data)
        guard spaces.first?.id == Self.defaultID,
              spaces.dropFirst().allSatisfy({ Self.isSpaceID($0.id) }),
              Set(spaces.map(\.id)).count == spaces.count else { throw SpaceError.invalid }
        return spaces
    }

    func save(id: String?, name: String) throws -> Space {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw SpaceError.invalid }
        var spaces = try list()
        guard !spaces.contains(where: { space in
            space.id != id && space.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw SpaceError.duplicate }
        let space = Space(id: id ?? UUID().uuidString.lowercased(), name: name)
        if let id {
            guard let index = spaces.firstIndex(where: { $0.id == id }) else { throw SpaceError.invalid }
            spaces[index] = space
        } else {
            spaces.append(space)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(spaces).write(to: catalog, options: .atomic)
        return space
    }

    func dataDirectory(for id: String) throws -> URL? {
        if id == Self.defaultID {
            return support.appendingPathComponent("Chrome ISP", isDirectory: true)
        }
        guard Self.isSpaceID(id), try list().contains(where: { $0.id == id }) else { return nil }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    func launchArguments(for id: String) throws -> [String]? {
        guard let data = try dataDirectory(for: id) else { return nil }
        let canonicalSupport = support.resolvingSymlinksInPath()
        let expected = id == Self.defaultID
            ? canonicalSupport.appendingPathComponent("Chrome ISP")
            : canonicalSupport.appendingPathComponent("Chrome ISP Spaces").appendingPathComponent(id)
        guard data.resolvingSymlinksInPath().path == expected.path else { throw SpaceError.invalid }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return [
            "--user-data-dir=" + data.path,
            "--profile-directory=Default",
            "--no-first-run",
            "--proxy-server=socks5://127.0.0.1:17890",
            "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
        ]
    }

    private static func isSpaceID(_ id: String) -> Bool {
        UUID(uuidString: id)?.uuidString.lowercased() == id
    }

    enum SpaceError: Error {
        case invalid, duplicate
    }
}
