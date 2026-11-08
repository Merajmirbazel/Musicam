#if DEBUG
import AppKit
import Domain
import Features

/// Debug builds only. Launch arguments let a test run drive the real app without anyone's music:
///   -MusicamPair create         make a pairing code and write it to <container tmp>/pair-code.txt
///   -MusicamDemo YES            make sample songs and import them
///   -MusicamFavorites YES       mark the first three imported songs as favorites
///   -MusicamPlaylistDemo YES    make a playlist with 5 songs, open it, select two rows and press Delete (tests removal)
///   -MusicamScreen songs|home|nowPlaying|devices|folders|repair
///   -MusicamSelect N            select the Nth song (newest first) in Songs
///   -MusicamPlay YES            start playing the first song
///   -MusicamSnapshot /path.png  save a picture of the window, then quit
///   -MusicamMerajfyTest <spotify link>  turn on the built-in downloader, download that link and write the result to <container tmp>/merajfy-test.txt
@MainActor
enum DebugSupport {
    static func run(_ model: AppModel) async {
        let defaults = UserDefaults.standard
        if let link = defaults.string(forKey: "MusicamMerajfyTest") { await merajfyTest(model, link: link) }
        if defaults.string(forKey: "MusicamPair") == "create" {
            await model.library.load()
            await model.sync.start()
            var code = model.sync.pairingCode
            if code == nil { code = await model.sync.createPairing() }
            try? (code ?? "").write(to: FileManager.default.temporaryDirectory.appendingPathComponent("pair-code.txt"), atomically: true, encoding: .utf8)
        }
        guard defaults.bool(forKey: "MusicamDemo") else { return }

        await model.library.load()
        if model.library.tracks.isEmpty {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MusicamSamples", isDirectory: true)
            guard let urls = try? await SampleSongs.generate(into: folder) else { return }
            model.library.startImport(urls)
            await waitUntil { model.library.tracks.count >= urls.count }
            if defaults.bool(forKey: "MusicamFavorites") {
                for track in model.library.tracks.prefix(3) { await model.library.edit(track.id, TrackEdit(isFavorite: true)) }
            }
        }

        switch defaults.string(forKey: "MusicamScreen") {
        case "songs": model.section = .songs
        case "nowPlaying": model.section = .nowPlaying
        case "devices": model.section = .devices
        case "folders": model.section = .folders
        case "repair": model.section = .repair
        case "downloads": model.section = .wishlist
        default: model.section = .home
        }
        if let index = defaults.string(forKey: "MusicamSelect").flatMap(Int.init) {
            let sorted = model.library.tracks.sorted { $0.addedAt > $1.addedAt }
            if sorted.indices.contains(index) { model.songSelection = [sorted[index].id] }
        }
        if defaults.bool(forKey: "MusicamPlay") {
            model.play(model.library.tracks.sorted { $0.title < $1.title }, startAt: 0)
            await waitUntil { model.playback.elapsed > 1.2 }
        }

        if defaults.string(forKey: "MusicamPlaylistDemo") != nil {
            await playlistDemo(model)
        }

        guard let path = defaults.string(forKey: "MusicamSnapshot") else { return }
        try? await Task.sleep(for: .seconds(3))
        NSApp.windows.forEach { $0.displayIfNeeded() }
        try? await Task.sleep(for: .seconds(0.5))
        snapshot(to: path)
        snapshotRightPane(to: path + ".right.png")
        NSApp.terminate(nil)
    }

    /// Builds a playlist, opens it, selects two rows in the real table and sends the Delete key, the way a person would.
    private static func playlistDemo(_ model: AppModel) async {
        let ids = model.library.tracks.sorted { $0.title < $1.title }.prefix(5).map(\.id)
        guard let list = await model.playlists.create(name: "Road", tracks: Array(ids)) else { return }
        model.section = UserDefaults.standard.string(forKey: "MusicamPlaylistDemo") == "songs" ? .songs : .playlist(list.id)
        try? await Task.sleep(for: .seconds(2))
        func tables(_ v: NSView) -> [NSTableView] { (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables) }
        guard let table = NSApp.windows.compactMap({ $0.contentView }).flatMap(tables).first else { note("DEMO no table found"); return }
        note("DEMO rows before: \(table.numberOfRows)")
        table.window?.makeFirstResponder(table)
        table.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)
        try? await Task.sleep(for: .seconds(1))
        table.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        try? await Task.sleep(for: .seconds(2))
        note("DEMO rows after delete key: \(table.numberOfRows) playlist=\(model.playlists.tracks(of: model.playlists.playlist(id: list.id)!).count) library=\(model.library.tracks.count) undo=\(model.undo.current?.message ?? "none")")
        await model.undo.perform()
        try? await Task.sleep(for: .seconds(1))
        note("DEMO after undo: playlist=\(model.playlists.tracks(of: model.playlists.playlist(id: list.id)!).count)")
    }

    private static func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// The inspector lives in its own hosting view on the right; render that view alone.
    private static func snapshotRightPane(to path: String) {
        guard let root = NSApp.windows.first(where: { $0.isVisible })?.contentView else { return }
        var candidates: [(NSView, CGFloat)] = []
        func walk(_ v: NSView) {
            let frame = v.convert(v.bounds, to: root)
            if String(describing: type(of: v)).contains("Hosting"), frame.minX > root.bounds.width * 0.6, frame.height > 200 {
                candidates.append((v, frame.width * frame.height))
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard let view = candidates.max(by: { $0.1 < $1.1 })?.0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            try? "no right pane view found".write(toFile: path + ".txt", atomically: true, encoding: .utf8); return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }

    private static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }
}

extension DebugSupport {
    /// Proves, inside the sandboxed app, that the built-in downloader really fetches a song into the library.
    static func merajfyTest(_ model: AppModel, link: String) async {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("merajfy-test.txt")
        var lines: [String] = []
        func log(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8) }
        let settings = model.merajfy
        log("sandboxed container: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "NO (not sandboxed)")")
        log("helpers present: \(settings.embedded.isAvailable)")
        // run the bundled programs directly (they inherit the sandbox) to see exactly what they can and cannot do
        if let dir = EmbeddedMerajfy.helpersDirectory {
            for (name, args) in [("yt-dlp_macos", ["--version"]), ("ffmpeg", ["-version"]),
                                 ("yt-dlp_macos", ["-J", "--flat-playlist", "--no-warnings", "ytsearch1:rick astley never gonna give you up"])] {
                let p = Process()
                p.executableURL = dir.appendingPathComponent(name)
                p.arguments = args
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                do {
                    try p.run()
                    let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    log("\(name) \(args.first ?? "") -> exit \(p.terminationStatus) | out: \(String(decoding: o, as: UTF8.self).prefix(160).replacingOccurrences(of: "\n", with: " ")) | err: \(String(decoding: e, as: UTF8.self).prefix(400).replacingOccurrences(of: "\n", with: " "))")
                } catch { log("\(name) could not launch: \(error)") }
            }
        }
        settings.mode = .builtIn
        settings.format = "mp3"
        settings.isEnabled = true
        await settings.testConnection()
        log("connection test: \(settings.status)  helper state: \(settings.embedded.state)")
        let outcome = await model.wishlist.submit(link)
        log("outcome: \(outcome)")
        let deadline = Date().addingTimeInterval(40)
        while model.library.tracks.isEmpty && Date() < deadline {
            await model.library.load()
            try? await Task.sleep(for: .milliseconds(300))
        }
        for t in model.library.tracks { log("library: \(t.title) | \(t.artist) | \(t.album)") }
        log("DONE tracks=\(model.library.tracks.count)")
        settings.isEnabled = false
        NSApp.terminate(nil)
    }
}
#endif
