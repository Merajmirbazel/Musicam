import Foundation
import Observation
import Domain
import Importing
import Metadata
import Acquisition

/// "Add from a link": remembers songs you want (from Spotify or YouTube links, by name only), downloads plain
/// audio files from direct links, and, when the Merajfy helper is turned on in Settings, downloads Spotify links
/// through it. Musicam itself never talks to a streaming service for audio.
@MainActor
@Observable
public final class WishlistModel {
    public enum Outcome: Equatable {
        case wishlisted(String)
        case alreadyListed
        case imported(String)
        case unsupported(String)
        case failed(String)
    }

    public private(set) var items: [WishItem] = []
    public private(set) var isWorking = false

    @ObservationIgnored private let store: WishlistStore
    @ObservationIgnored private let fetcher: any LinkInfoFetching
    @ObservationIgnored private let downloader: DirectAudioDownloader
    @ObservationIgnored private let importFiles: @MainActor ([URL], String?) -> Void
    /// When set, direct audio links go through the Media Acquisition layer; when nil they are downloaded here as before.
    @ObservationIgnored private let acquisition: AcquisitionManager?

    public init(store: WishlistStore, fetcher: any LinkInfoFetching, downloader: DirectAudioDownloader,
                importFiles: @escaping @MainActor ([URL], String?) -> Void, acquisition: AcquisitionManager? = nil) {
        self.acquisition = acquisition
        self.store = store
        self.fetcher = fetcher
        self.downloader = downloader
        self.importFiles = importFiles
    }

    public func load() async { items = await store.all() }

    public func remove(_ id: UUID) async {
        await store.remove(id)
        await load()
    }

    /// The library song that fulfils a wish, if there is one.
    public func match(for wish: WishItem, in tracks: [Track]) -> Track? {
        tracks.first { WishMatcher.matches(wish, title: $0.title, artist: $0.artist) }
    }

    public func pendingCount(in tracks: [Track]) -> Int {
        items.filter { match(for: $0, in: tracks) == nil }.count
    }

    public func submit(_ text: String) async -> Outcome {
        isWorking = true
        defer { isWorking = false }
        let kind = LinkParser.classify(text)
        switch kind {
        case .notALink:
            return .failed(String(localized: "That does not look like a link to a song or an audio file."))
        case .unsupportedService(let host):
            return .unsupported(host)
        case .spotify(let url) where [MerajfyProvider.providerID, MerajfyLocalProvider.providerID].contains(acquisition?.providerID(for: .link(url)) ?? ""):
            // Merajfy is set up: get the song itself instead of only remembering its name.
            guard let acquisition else { return .failed(AcquisitionError.noProvider.localizedDescription) }
            let name = (try? await fetcher.info(for: kind))?.title
            let job = await acquisition.perform(.link(url))
            switch job.state {
            case .finished: return .imported(name ?? String(localized: "Spotify"))
            case .failed(let error): return .failed(error.localizedDescription)
            default: return .failed(AcquisitionError.cancelled.localizedDescription)
            }
        case .spotify(let url), .youtube(let url):
            do {
                let info = try await fetcher.info(for: kind)
                let added = await store.add(WishItem(title: info.title, artist: info.artist, sourceURL: url, thumbnailURL: info.thumbnailURL))
                await load()
                return added ? .wishlisted(info.title) : .alreadyListed
            } catch {
                return .failed(error.localizedDescription)
            }
        case .directAudio(let url):
            if let acquisition {
                let job = await acquisition.perform(.link(url))
                switch job.state {
                case .finished: return .imported(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
                case .failed(let error): return .failed(error.localizedDescription)
                default: return .failed(AcquisitionError.cancelled.localizedDescription)
                }
            }
            do {
                let file = try await downloader.download(url)
                importFiles([file], TrackSource.link(url: url).raw)
                return .imported(file.lastPathComponent)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }
}
