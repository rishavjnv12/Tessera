#import "TKInternal.h"

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/session_stats.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <boost/asio/ip/address.hpp>

#include <os/log.h>

#include <algorithm>
#include <cmath>
#include <atomic>
#include <chrono>
#include <climits>
#include <map>
#include <tuple>
#include <set>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>

namespace {

using Clock = std::chrono::steady_clock;

constexpr auto kTickInterval = std::chrono::seconds(1);
constexpr auto kResumeSaveInterval = std::chrono::seconds(30);
constexpr char const *kResumeExtension = ".fastresume";
constexpr char const *kSessionStateFile = "session.state";
constexpr char const *kStreamingExtension = ".fromstart";
/// Download-from-start ("this file first, in order"): other files pause, the torrent switches to
/// sequential order, and the file's last kFileEndBytes get priority 7 so they arrive early.
/// Everything is restored when the file is complete or the user stops.
///
/// Measured alternatives that let the start of the file arrive late:
/// - deadlines on a large window alone: libtorrent queues deadline requests behind a peer's
///   ordinary requests (deadlines stay only on the next few pieces, see kStreamingHeadPieces);
/// - priority 7 windows, or the whole file at 7: libtorrent picks priority-7 pieces rarest-first
///   ahead of any order, and the first pieces were among the last to arrive;
/// - priorities 5-6 without pausing other files: below 7, priority only weights the rarest-first
///   choice, so other files kept taking bandwidth.
constexpr std::int64_t kFileEndBytes = 1024 * 1024;
/// The next missing pieces, about kStreamingHeadBytes, also get a deadline. With several peers,
/// libtorrent then asks a faster peer for a piece that is late, so one slow peer cannot hold up
/// the start of the file. Kept small: a large deadline window pushes pieces out of order again.
constexpr std::int64_t kStreamingHeadBytes = 1024 * 1024;
constexpr int kStreamingMinHeadPieces = 4;
constexpr int kStreamingMaxHeadPieces = 16;

os_log_t TKLog() {
    static os_log_t log = os_log_create("io.github.rishavjnv12.TesseraKit", "session");
    return log;
}

struct Entry {
    lt::torrent_handle handle;
    std::uint64_t order = 0;
    int64_t downloadLimit = 0;
    int64_t uploadLimit = 0;
    /// Restored torrents that were already complete: skip the "finished" event after the check.
    bool suppressFinishedEvent = false;
    /// Hand-set piece priorities to re-apply once libtorrent confirms a file priority change,
    /// because that confirmation resets every piece to its files' priority.
    std::map<int, lt::download_priority_t> pieceRestore;
    int pendingFilePriorityUpdates = 0;
    /// File being downloaded from its start, or -1.
    int streamingFile = -1;
    /// Every file's priority and the sequential flag from before, restored when it ends.
    std::vector<lt::download_priority_t> streamingSavedPriorities;
    bool streamingSavedSequential = false;
    /// Pieces at the front already given a deadline (set once: setting one again re-requests the piece).
    std::set<int> streamingDeadlines;
    /// File priorities just restored after download-from-start, checked again shortly after.
    /// libtorrent sometimes updated the file priorities but left their pieces at 0 (seen about
    /// one run in five), which kept the other files from resuming.
    std::vector<lt::download_priority_t> restoreCheck;
    Clock::time_point restoreCheckAt;
};

int ClampLimit(int64_t v) { return static_cast<int>(std::clamp<int64_t>(v, 0, INT_MAX)); }

int64_t NormalizeLimit(int v) { return v > 0 ? v : 0; }

} // namespace

static std::vector<lt::download_priority_t> TKPiecePrioritiesFromFiles(
    lt::file_storage const &fs, std::vector<lt::download_priority_t> const &filePriorities);

struct TKFileReadiness {
    int64_t contiguousBytes = 0;
    bool hasEnd = false;
    /// First piece of the file not downloaded yet, or -1 when the file is complete.
    int firstMissingPiece = -1;
};

/// How much of a file can be read from its start, and whether its end is present.
static TKFileReadiness TKReadiness(lt::file_storage const &fs, lt::file_index_t f,
                                   lt::typed_bitfield<lt::piece_index_t> const &have) {
    TKFileReadiness r;
    int64_t const size = fs.file_size(f);
    if (size <= 0) {
        r.hasEnd = true;
        return r;
    }
    auto const has = [&](int p) { return p < have.size() && have.get_bit(lt::piece_index_t(p)); };
    int const first = static_cast<int>(fs.map_file(f, 0, 1).piece);
    int const last = static_cast<int>(fs.map_file(f, size - 1, 1).piece);
    int missing = first;
    while (missing <= last && has(missing)) ++missing;
    if (missing > last) {
        r.contiguousBytes = size;
    } else {
        int64_t const readableEnd = int64_t(missing) * fs.piece_length(); // offset in the torrent
        r.contiguousBytes = std::clamp<int64_t>(readableEnd - fs.file_offset(f), 0, size);
        r.firstMissingPiece = missing;
    }
    int const endStart = static_cast<int>(fs.map_file(f, std::max<int64_t>(0, size - kFileEndBytes), 1).piece);
    r.hasEnd = true;
    for (int p = endStart; p <= last; ++p) {
        if (!has(p)) { r.hasEnd = false; break; }
    }
    return r;
}

struct TKSessionImpl {
    std::unique_ptr<lt::session> session;
    std::thread alertThread;
    std::atomic<bool> stopping{false};

    /// Guards everything below, and resume-file writes, so a removed torrent's file is never re-created.
    std::mutex mutex;
    std::unordered_map<std::string, Entry> entries;
    std::unordered_map<std::uint32_t, std::string> idsByHandle; // torrent_handle::id() -> torrent ID
    std::unordered_map<std::string, TKTorrentStatus *> statuses;
    /// best-hash hex -> (torrent ID, name) for torrents whose files are being deleted.
    std::unordered_map<std::string, std::pair<std::string, std::string>> pendingDeletes;
    std::uint64_t nextOrder = 0;

    std::atomic<long> dhtNodes{0};
    std::atomic<long> listenPort{0};
    int dhtNodesMetric = -1;
    bool pexEnabled = true;
};

@implementation TKSession {
    std::shared_ptr<TKSessionImpl> _impl; // shared with the alert thread
    dispatch_queue_t _deliveryQueue;
    std::atomic<bool> _closed;
}

@synthesize settings = _settings;

// MARK: - Lifecycle

- (nullable instancetype)initWithStateDirectory:(NSURL *)stateDirectory
                                defaultSavePath:(NSURL *)defaultSavePath
                                       settings:(TKSessionSettings *)settings
                                          error:(NSError **)error {
    if (!(self = [super init])) return nil;

    _stateDirectory = [stateDirectory copy];
    _defaultSavePath = [defaultSavePath copy];
    _settings = [settings copy];
    _closed = false;
    _deliveryQueue = dispatch_queue_create("io.github.rishavjnv12.TesseraKit.delivery", DISPATCH_QUEUE_SERIAL);
    _impl = std::make_shared<TKSessionImpl>();
    _impl->pexEnabled = settings.enablePEX;
    _impl->dhtNodesMetric = lt::find_metric_idx("dht.dht_nodes");

    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSURL *dir in @[stateDirectory, defaultSavePath]) {
        NSError *dirError = nil;
        if (![fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&dirError]) {
            if (error) *error = TKMakeError(TKErrorFileSystem,
                [NSString stringWithFormat:@"Could not create %@: %@", dir.path, dirError.localizedDescription]);
            return nil;
        }
    }

    try {
        lt::session_params params;
        NSData *state = [NSData dataWithContentsOfURL:[stateDirectory URLByAppendingPathComponent:@(kSessionStateFile)]];
        if (state.length > 0) {
            lt::error_code ec;
            lt::bdecode_node node = lt::bdecode({static_cast<char const *>(state.bytes), static_cast<long>(state.length)}, ec);
            if (!ec) {
                params = lt::read_session_params(node, lt::session::save_dht_state);
            }
        }
        params.settings = TKSettingsPack(settings);
        _impl->session = std::make_unique<lt::session>(std::move(params));
    } catch (std::exception const &e) {
        if (error) *error = TKMakeError(TKErrorEngine, [NSString stringWithFormat:@"Could not start session: %s", e.what()]);
        return nil;
    }

    [self restoreTorrents];

    std::shared_ptr<TKSessionImpl> impl = _impl;
    __weak TKSession *weakSelf = self;
    impl->alertThread = std::thread([impl, weakSelf] {
        pthread_setname_np("TesseraKit.alerts");
        auto lastTick = Clock::now() - kTickInterval;
        auto lastSave = Clock::now();
        while (!impl->stopping.load()) {
            impl->session->wait_for_alert(std::chrono::milliseconds(250));
            if (impl->stopping.load()) break;
            @autoreleasepool {
                TKSession *strongSelf = weakSelf;
                if (!strongSelf) break;
                std::vector<lt::alert *> alerts;
                impl->session->pop_alerts(&alerts);
                for (lt::alert *a : alerts) {
                    try {
                        [strongSelf handleAlert:a];
                    } catch (std::exception const &e) {
                        os_log_error(TKLog(), "Alert handling failed: %{public}s", e.what());
                    }
                }
                auto const now = Clock::now();
                if (now - lastTick >= kTickInterval) {
                    lastTick = now;
                    impl->session->post_torrent_updates();
                    impl->session->post_session_stats();
                    [strongSelf updateStreamingWindows];
                    [strongSelf verifyRestoredPriorities];
                }
                if (now - lastSave >= kResumeSaveInterval) {
                    lastSave = now;
                    [strongSelf requestResumeData:lt::torrent_handle::only_if_modified];
                }
            }
        }
    });
    return self;
}

- (void)dealloc {
    [self shutdown];
}

- (BOOL)isClosed {
    return _closed.load();
}

- (void)shutdown {
    if (_closed.exchange(true)) return;
    TKSessionImpl *impl = _impl.get();
    impl->stopping = true;
    if (impl->alertThread.joinable()) {
        if (impl->alertThread.get_id() == std::this_thread::get_id()) {
            impl->alertThread.detach(); // last reference dropped on the alert thread itself
        } else {
            impl->alertThread.join();
        }
    }

    // Save every torrent synchronously so nothing depends on alerts that will never be read.
    std::vector<std::pair<std::string, lt::torrent_handle>> handles;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        for (auto const &[torrentID, entry] : impl->entries) handles.emplace_back(torrentID, entry.handle);
    }
    for (auto const &[torrentID, handle] : handles) {
        try {
            if (!handle.is_valid()) continue;
            lt::add_torrent_params atp = handle.get_resume_data(lt::torrent_handle::save_info_dict);
            std::lock_guard<std::mutex> lock(impl->mutex);
            if (impl->entries.count(torrentID)) [self writeResumeData:atp forID:torrentID];
        } catch (std::exception const &e) {
            os_log_error(TKLog(), "Saving resume data on shutdown failed: %{public}s", e.what());
        }
    }

    try {
        lt::session_params state = impl->session->session_state(lt::session::save_dht_state);
        std::vector<char> buf = lt::write_session_params_buf(state, lt::session::save_dht_state);
        NSData *data = [NSData dataWithBytes:buf.data() length:buf.size()];
        [data writeToURL:[_stateDirectory URLByAppendingPathComponent:@(kSessionStateFile)] atomically:YES];
    } catch (std::exception const &e) {
        os_log_error(TKLog(), "Saving session state failed: %{public}s", e.what());
    }

    impl->session.reset(); // blocks until libtorrent has shut down
    os_log_info(TKLog(), "Session shut down with %lu torrents saved", handles.size());

    void (^closeHandler)(void) = self.closeHandler;
    if (closeHandler) dispatch_async(_deliveryQueue, closeHandler);
}

// MARK: - Settings

- (TKSessionSettings *)settings {
    @synchronized(self) {
        return [_settings copy];
    }
}

- (void)applySettings:(TKSessionSettings *)settings {
    if (self.closed) return;
    @synchronized(self) {
        _settings = [settings copy];
    }
    _impl->session->apply_settings(TKSettingsPack(settings));

    std::lock_guard<std::mutex> lock(_impl->mutex);
    if (_impl->pexEnabled != static_cast<bool>(settings.enablePEX)) {
        _impl->pexEnabled = settings.enablePEX;
        for (auto &[torrentID, entry] : _impl->entries) {
            if (settings.enablePEX) entry.handle.unset_flags(lt::torrent_flags::disable_pex);
            else entry.handle.set_flags(lt::torrent_flags::disable_pex);
        }
    }
}

- (NSInteger)listenPort {
    if (self.closed) return 0;
    return _impl->session->listen_port();
}

// MARK: - Adding

- (nullable NSString *)addTorrentFileAtURL:(NSURL *)url options:(nullable TKAddTorrentOptions *)options error:(NSError **)error {
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readError];
    if (!data) {
        if (error) *error = TKMakeError(TKErrorFileSystem,
            [NSString stringWithFormat:@"Could not read %@: %@", url.lastPathComponent, readError.localizedDescription]);
        return nil;
    }
    return [self addTorrentData:data options:options error:error];
}

- (nullable NSString *)addTorrentData:(NSData *)data options:(nullable TKAddTorrentOptions *)options error:(NSError **)error {
    lt::add_torrent_params atp;
    try {
        lt::error_code ec;
        lt::bdecode_node node = lt::bdecode({static_cast<char const *>(data.bytes), static_cast<long>(data.length)}, ec);
        if (ec) throw lt::system_error(ec);
        atp = lt::load_torrent_parsed(node);
    } catch (std::exception const &e) {
        if (error) *error = TKMakeError(TKErrorInvalidTorrent, [NSString stringWithFormat:@"Not a valid torrent: %s", e.what()]);
        return nil;
    }
    return [self addParams:std::move(atp) options:options error:error];
}

- (nullable NSString *)addMagnetLink:(NSString *)magnetLink options:(nullable TKAddTorrentOptions *)options error:(NSError **)error {
    lt::error_code ec;
    lt::add_torrent_params atp = lt::parse_magnet_uri(magnetLink.UTF8String ?: "", ec);
    if (ec) {
        if (error) *error = TKMakeError(TKErrorInvalidMagnet, [NSString stringWithFormat:@"Not a valid magnet link: %s", ec.message().c_str()]);
        return nil;
    }
    return [self addParams:std::move(atp) options:options error:error];
}

- (nullable NSString *)addParams:(lt::add_torrent_params)atp options:(nullable TKAddTorrentOptions *)options error:(NSError **)error {
    if (self.closed) {
        if (error) *error = TKMakeError(TKErrorSessionClosed, @"The session is closed.");
        return nil;
    }
    NSURL *savePath = options.savePath ?: _defaultSavePath;
    atp.save_path = savePath.path.fileSystemRepresentation;
    if (options.startPaused) {
        atp.flags |= lt::torrent_flags::paused;
        atp.flags &= ~lt::torrent_flags::auto_managed;
    }
    if (options.filePriorities.count > 0 && atp.ti) {
        int const fileCount = atp.ti->layout().num_files();
        atp.file_priorities.assign(std::size_t(fileCount), lt::default_priority);
        for (NSUInteger i = 0; i < options.filePriorities.count && i < NSUInteger(fileCount); ++i) {
            atp.file_priorities[i] = lt::download_priority_t(std::uint8_t(std::clamp(options.filePriorities[i].intValue, 0, 7)));
        }
    }
    std::string const torrentID = TKHexID(atp.ti ? atp.ti->info_hashes() : atp.info_hashes);
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        if (_impl->entries.count(torrentID)) {
            if (error) *error = TKMakeError(TKErrorDuplicateTorrent, @"This torrent is already in the list.");
            return nil;
        }
    }
    NSString *name = nil;
    if (![self addToSession:std::move(atp) torrentID:torrentID suppressFinishedEvent:false name:&name error:error]) {
        return nil;
    }
    NSString *idString = @(torrentID.c_str());
    [self deliverEvent:[[TKTorrentEvent alloc] initWithKind:TKTorrentEventKindAdded torrentID:idString torrentName:name message:nil]];
    return idString;
}

/// Adds to libtorrent and registers the entry. Used for new torrents and for restoring saved ones.
- (BOOL)addToSession:(lt::add_torrent_params)atp
           torrentID:(std::string const &)torrentID
suppressFinishedEvent:(bool)suppressFinished
                name:(NSString *_Nullable *_Nullable)outName
               error:(NSError **)error {
    Entry entry;
    entry.downloadLimit = NormalizeLimit(atp.download_limit);
    entry.uploadLimit = NormalizeLimit(atp.upload_limit);
    entry.suppressFinishedEvent = suppressFinished;
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        if (!_impl->pexEnabled) atp.flags |= lt::torrent_flags::disable_pex;
        else atp.flags &= ~lt::torrent_flags::disable_pex;
    }

    lt::error_code ec;
    lt::torrent_handle handle = _impl->session->add_torrent(std::move(atp), ec);
    if (ec) {
        TKErrorCode code = (ec == lt::errors::duplicate_torrent) ? TKErrorDuplicateTorrent : TKErrorEngine;
        NSString *message = (code == TKErrorDuplicateTorrent) ? @"This torrent is already in the list." : TKString(ec.message());
        if (error) *error = TKMakeError(code, message);
        return NO;
    }
    entry.handle = handle;

    NSString *idString = @(torrentID.c_str());
    TKTorrentStatus *status = [[TKTorrentStatus alloc] initWithID:idString status:handle.status()
                                                    downloadLimit:entry.downloadLimit uploadLimit:entry.uploadLimit
                                         fileDownloadingFromStart:entry.streamingFile];
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        entry.order = _impl->nextOrder++;
        _impl->idsByHandle[handle.id()] = torrentID;
        _impl->entries[torrentID] = entry;
        _impl->statuses[torrentID] = status;
    }
    handle.save_resume_data(lt::torrent_handle::save_info_dict);
    if (outName) *outName = status.name;
    return YES;
}

/// Maps a save path that points into a previous copy of this app's container onto the current one.
/// An iOS app's data container is ".../Containers/Data/Application/<UUID>/"; the UUID can change after
/// a reinstall or an update while the data moves with it, so saved absolute paths go stale. Returns
/// nil when the path does not need to change.
static NSString *_Nullable TKRelocatedSavePath(NSString *path) {
    auto strip = [](NSString *s) { return [s hasPrefix:@"/private/"] ? [s substringFromIndex:8] : s; };
    NSString *home = strip(NSHomeDirectory().stringByStandardizingPath);
    NSString *saved = strip(path.stringByStandardizingPath);
    NSString *containers = home.stringByDeletingLastPathComponent; // .../Application (iOS)
    if (![containers.lastPathComponent isEqualToString:@"Application"]) return nil; // not an iOS data container
    NSString *prefix = [containers stringByAppendingString:@"/"];
    if (![saved hasPrefix:prefix] || [saved hasPrefix:[home stringByAppendingString:@"/"]] || [saved isEqualToString:home]) return nil;
    NSArray<NSString *> *rest = [saved substringFromIndex:prefix.length].pathComponents; // <old UUID>/Documents/...
    if (rest.count < 2) return nil;
    return [NSString pathWithComponents:[@[home] arrayByAddingObjectsFromArray:[rest subarrayWithRange:NSMakeRange(1, rest.count - 1)]]];
}

- (void)restoreTorrents {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSURL *> *files = [fm contentsOfDirectoryAtURL:_stateDirectory includingPropertiesForKeys:nil options:0 error:nil];
    std::vector<std::pair<std::string, lt::add_torrent_params>> saved;
    NSString *extension = [@(kResumeExtension) substringFromIndex:1];
    for (NSURL *url in files) {
        if (![url.pathExtension isEqualToString:extension]) continue;
        NSData *data = [NSData dataWithContentsOfURL:url];
        lt::error_code ec;
        lt::add_torrent_params atp;
        if (data.length > 0) {
            atp = lt::read_resume_data({static_cast<char const *>(data.bytes), static_cast<long>(data.length)}, ec);
        }
        if (data.length == 0 || ec) {
            os_log_error(TKLog(), "Unreadable resume file %{public}@: %{public}s", url.lastPathComponent, ec.message().c_str());
            [fm moveItemAtURL:url toURL:[url URLByAppendingPathExtension:@"bad"] error:nil];
            continue;
        }
        saved.emplace_back(url.URLByDeletingPathExtension.lastPathComponent.UTF8String, std::move(atp));
    }
    std::sort(saved.begin(), saved.end(), [](auto const &a, auto const &b) {
        return a.second.added_time < b.second.added_time;
    });
    for (auto &[torrentID, atp] : saved) {
        if (NSString *moved = TKRelocatedSavePath(TKString(atp.save_path))) {
            os_log_info(TKLog(), "Save path moved with the app container: %{public}@", moved);
            atp.save_path = moved.fileSystemRepresentation;
            // What the old resume data says is on disk may be out of date; check the files again.
            atp.have_pieces.clear();
            atp.verified_pieces.clear();
            atp.unfinished_pieces.clear();
        }
        bool const wasComplete = atp.completed_time > 0;
        NSError *error = nil;
        if (![self addToSession:std::move(atp) torrentID:torrentID suppressFinishedEvent:wasComplete name:nil error:&error]) {
            os_log_error(TKLog(), "Could not restore %{public}s: %{public}@", torrentID.c_str(), error.localizedDescription);
            continue;
        }
        NSString *streaming = [NSString stringWithContentsOfURL:[self streamingURLForID:torrentID] encoding:NSUTF8StringEncoding error:nil];
        if (streaming.length > 0) {
            std::lock_guard<std::mutex> lock(_impl->mutex);
            auto it = _impl->entries.find(torrentID);
            NSArray<NSString *> *parts = [streaming componentsSeparatedByString:@" "];
            if (it != _impl->entries.end() && parts.count >= 3) {
                it->second.streamingFile = parts[0].intValue;
                it->second.streamingSavedSequential = parts[1].intValue != 0;
                for (NSString *level in [parts[2] componentsSeparatedByString:@","]) {
                    it->second.streamingSavedPriorities.push_back(lt::download_priority_t(std::uint8_t(level.intValue)));
                }
            }
        }
        lt::torrent_handle h;
        if ([self handleForID:@(torrentID.c_str()) handle:&h error:nil]) [self refreshStatusForID:@(torrentID.c_str()) handle:h];
    }
    os_log_info(TKLog(), "Restored %lu torrents", saved.size());
}

// MARK: - Removing

- (BOOL)removeTorrent:(NSString *)torrentID deleteFiles:(BOOL)deleteFiles error:(NSError **)error {
    if (![self checkOpen:error]) return NO;
    std::string const key = torrentID.UTF8String;
    lt::torrent_handle handle;
    NSString *name = nil;
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(key);
        if (it == _impl->entries.end()) {
            if (error) *error = TKMakeError(TKErrorTorrentNotFound, @"No such torrent.");
            return NO;
        }
        handle = it->second.handle;
        name = _impl->statuses[key].name;
        _impl->idsByHandle.erase(handle.id());
        _impl->statuses.erase(key);
        _impl->entries.erase(it);
        [[NSFileManager defaultManager] removeItemAtURL:[self resumeURLForID:key] error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:[self streamingURLForID:key] error:nil];
        if (deleteFiles) {
            _impl->pendingDeletes[TKHexID(handle.info_hashes())] = {key, name.UTF8String ?: ""};
        }
    }
    _impl->session->remove_torrent(handle, deleteFiles ? lt::session::delete_files : lt::remove_flags_t{});
    [self deliverEvent:[[TKTorrentEvent alloc] initWithKind:TKTorrentEventKindRemoved torrentID:torrentID torrentName:name message:nil]];
    return YES;
}

// MARK: - Control

- (BOOL)checkOpen:(NSError **)error {
    if (!self.closed) return YES;
    if (error) *error = TKMakeError(TKErrorSessionClosed, @"The session is closed.");
    return NO;
}

/// Looks up the handle for an ID, or fills `error`.
- (BOOL)handleForID:(NSString *)torrentID handle:(lt::torrent_handle *)outHandle error:(NSError **)error {
    if (![self checkOpen:error]) return NO;
    std::lock_guard<std::mutex> lock(_impl->mutex);
    auto it = _impl->entries.find(torrentID.UTF8String);
    if (it == _impl->entries.end()) {
        if (error) *error = TKMakeError(TKErrorTorrentNotFound, @"No such torrent.");
        return NO;
    }
    *outHandle = it->second.handle;
    return YES;
}

- (void)refreshStatusForID:(NSString *)torrentID handle:(lt::torrent_handle const &)handle {
    lt::torrent_status st = handle.status();
    std::lock_guard<std::mutex> lock(_impl->mutex);
    auto it = _impl->entries.find(torrentID.UTF8String);
    if (it == _impl->entries.end()) return;
    _impl->statuses[it->first] = [[TKTorrentStatus alloc] initWithID:torrentID status:st
                                                       downloadLimit:it->second.downloadLimit
                                                         uploadLimit:it->second.uploadLimit
                                            fileDownloadingFromStart:it->second.streamingFile];
}

- (BOOL)pauseTorrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:error]) return NO;
    h.unset_flags(lt::torrent_flags::auto_managed);
    h.pause();
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    [self refreshStatusForID:torrentID handle:h];
    return YES;
}

- (BOOL)resumeTorrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:error]) return NO;
    h.set_flags(lt::torrent_flags::auto_managed);
    h.resume();
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    [self refreshStatusForID:torrentID handle:h];
    return YES;
}

- (BOOL)recheckTorrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:error]) return NO;
    h.force_recheck();
    [self refreshStatusForID:torrentID handle:h];
    return YES;
}

- (BOOL)setDownloadLimit:(int64_t)downloadLimit uploadLimit:(int64_t)uploadLimit forTorrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:error]) return NO;
    if (downloadLimit < 0 || uploadLimit < 0) {
        if (error) *error = TKMakeError(TKErrorInvalidArgument, @"Limits must be zero or positive.");
        return NO;
    }
    h.set_download_limit(downloadLimit > 0 ? ClampLimit(downloadLimit) : -1);
    h.set_upload_limit(uploadLimit > 0 ? ClampLimit(uploadLimit) : -1);
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(torrentID.UTF8String);
        if (it != _impl->entries.end()) {
            it->second.downloadLimit = downloadLimit;
            it->second.uploadLimit = uploadLimit;
        }
    }
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    [self refreshStatusForID:torrentID handle:h];
    return YES;
}

// MARK: - Priorities

/// Looks up a torrent whose priorities can change: it has metadata and is not complete.
- (std::shared_ptr<lt::torrent_info const>)prioritizableTorrent:(NSString *)torrentID
                                                          handle:(lt::torrent_handle *)outHandle
                                                        priority:(uint8_t)priority
                                                           error:(NSError **)error {
    if (![self handleForID:torrentID handle:outHandle error:error]) return nullptr;
    if (priority > 7) {
        if (error) *error = TKMakeError(TKErrorInvalidArgument, @"Priority must be between 0 and 7.");
        return nullptr;
    }
    std::shared_ptr<lt::torrent_info const> ti = outHandle->torrent_file();
    if (!ti) {
        if (error) *error = TKMakeError(TKErrorNoMetadata, @"Priorities can be set once the torrent's details have arrived.");
        return nullptr;
    }
    if (outHandle->status({}).is_seeding) {
        if (error) *error = TKMakeError(TKErrorTorrentComplete, @"Every piece is already downloaded.");
        return nullptr;
    }
    return ti;
}

/// Piece priorities implied by file priorities alone: each piece takes the highest
/// priority of the files it holds bytes of. This is how libtorrent derives them.
static std::vector<lt::download_priority_t> TKPiecePrioritiesFromFiles(
    lt::file_storage const &fs, std::vector<lt::download_priority_t> const &filePriorities) {
    std::vector<lt::download_priority_t> pieces(std::size_t(fs.num_pieces()), lt::dont_download);
    for (lt::file_index_t f : fs.file_range()) {
        auto const i = std::size_t(static_cast<int>(f));
        if (fs.pad_file_at(f) || fs.file_size(f) == 0 || i >= filePriorities.size()) continue;
        int const first = static_cast<int>(fs.map_file(f, 0, 1).piece);
        int const last = static_cast<int>(fs.map_file(f, fs.file_size(f) - 1, 1).piece);
        for (int p = first; p <= last; ++p) {
            pieces[std::size_t(p)] = std::max(pieces[std::size_t(p)], filePriorities[i]);
        }
    }
    return pieces;
}

- (BOOL)setPriority:(uint8_t)priority forFiles:(NSIndexSet *)files torrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    auto ti = [self prioritizableTorrent:torrentID handle:&h priority:priority error:error];
    if (!ti) return NO;
    lt::file_storage const &fs = ti->layout();
    int const fileCount = fs.num_files();
    if (files.count == 0 || files.lastIndex >= NSUInteger(fileCount)) {
        if (error) *error = TKMakeError(TKErrorInvalidArgument, @"No such file in this torrent.");
        return NO;
    }

    std::vector<lt::download_priority_t> filePriorities = h.get_file_priorities();
    filePriorities.resize(std::size_t(fileCount), lt::default_priority);
    std::vector<lt::download_priority_t> const piecePriorities = h.get_piece_priorities();
    std::vector<lt::download_priority_t> const implied = TKPiecePrioritiesFromFiles(fs, filePriorities);

    // libtorrent resets every piece to its files' priority when a file priority changes.
    // Remember hand-set pieces outside the changed files so they can be restored.
    std::vector<bool> changed(std::size_t(fs.num_pieces()), false);
    for (NSUInteger index = files.firstIndex; index != NSNotFound; index = [files indexGreaterThanIndex:index]) {
        lt::file_index_t const f(static_cast<int>(index));
        filePriorities[index] = lt::download_priority_t(priority);
        if (fs.pad_file_at(f) || fs.file_size(f) == 0) continue;
        int const first = static_cast<int>(fs.map_file(f, 0, 1).piece);
        int const last = static_cast<int>(fs.map_file(f, fs.file_size(f) - 1, 1).piece);
        for (int p = first; p <= last; ++p) changed[std::size_t(p)] = true;
    }
    std::vector<std::pair<lt::piece_index_t, lt::download_priority_t>> handSet;
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(torrentID.UTF8String);
        if (it == _impl->entries.end()) return NO;
        Entry &entry = it->second;
        // Pieces still waiting from an earlier change are more accurate than the current
        // (possibly already reset) priorities, unless they belong to a file changed now.
        for (auto r = entry.pieceRestore.begin(); r != entry.pieceRestore.end();) {
            r = changed[std::size_t(r->first)] ? entry.pieceRestore.erase(r) : std::next(r);
        }
        for (std::size_t p = 0; p < piecePriorities.size() && p < implied.size(); ++p) {
            if (!changed[p] && piecePriorities[p] != implied[p]) entry.pieceRestore.emplace(int(p), piecePriorities[p]);
        }
        for (auto const &[piece, prio] : entry.pieceRestore) handSet.emplace_back(lt::piece_index_t(piece), prio);
        entry.pendingFilePriorityUpdates += 1;
    }

    h.prioritize_files(filePriorities);
    if (!handSet.empty()) h.prioritize_pieces(handSet);
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    [self refreshStatusForID:torrentID handle:h];
    return YES;
}

- (BOOL)setPriority:(uint8_t)priority forPieceRange:(NSRange)range torrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    auto ti = [self prioritizableTorrent:torrentID handle:&h priority:priority error:error];
    if (!ti) return NO;
    if (range.length == 0 || NSMaxRange(range) > NSUInteger(ti->num_pieces())) {
        if (error) *error = TKMakeError(TKErrorInvalidArgument, @"Those pieces are outside this torrent.");
        return NO;
    }
    std::vector<std::pair<lt::piece_index_t, lt::download_priority_t>> pieces;
    pieces.reserve(range.length);
    for (NSUInteger p = range.location; p < NSMaxRange(range); ++p) {
        pieces.emplace_back(lt::piece_index_t(int(p)), lt::download_priority_t(priority));
    }
    {
        // If a file priority change is still being applied, make sure it does not undo this.
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(torrentID.UTF8String);
        if (it != _impl->entries.end() && it->second.pendingFilePriorityUpdates > 0) {
            for (NSUInteger p = range.location; p < NSMaxRange(range); ++p) {
                it->second.pieceRestore[int(p)] = lt::download_priority_t(priority);
            }
        }
    }
    h.prioritize_pieces(pieces);
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    [self refreshStatusForID:torrentID handle:h];
    return YES;
}

// MARK: - Download order

- (BOOL)setSequential:(BOOL)sequential forTorrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:error]) return NO;
    if (sequential) h.set_flags(lt::torrent_flags::sequential_download);
    else h.unset_flags(lt::torrent_flags::sequential_download);
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    [self refreshStatusForID:torrentID handle:h];
    return YES;
}

- (NSURL *)streamingURLForID:(std::string const &)torrentID {
    return [_stateDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"%s%s", torrentID.c_str(), kStreamingExtension]];
}

- (BOOL)downloadFileFromStart:(NSInteger)fileIndex torrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    auto ti = [self prioritizableTorrent:torrentID handle:&h priority:7 error:error];
    if (!ti) return NO;
    lt::file_storage const &fs = ti->layout();
    if (fileIndex < 0 || fileIndex >= fs.num_files() || fs.pad_file_at(lt::file_index_t(int(fileIndex)))
        || fs.file_size(lt::file_index_t(int(fileIndex))) == 0) {
        if (error) *error = TKMakeError(TKErrorInvalidArgument, @"No such file in this torrent.");
        return NO;
    }
    std::string const key = torrentID.UTF8String;
    int previousFile = -1;
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(key);
        if (it == _impl->entries.end()) return NO;
        previousFile = it->second.streamingFile;
    }
    if (previousFile >= 0) [self endStreamingForID:key handle:h]; // one file at a time; restore first

    std::vector<lt::download_priority_t> saved = h.get_file_priorities();
    saved.resize(std::size_t(fs.num_files()), lt::default_priority);
    bool const savedSequential = static_cast<bool>(h.flags() & lt::torrent_flags::sequential_download);

    // Every other file pauses; this one gets at least normal priority (below 7, see above).
    NSMutableIndexSet *others = [NSMutableIndexSet indexSet];
    for (int f = 0; f < fs.num_files(); ++f) {
        if (f != fileIndex && saved[std::size_t(f)] != lt::dont_download && !fs.pad_file_at(lt::file_index_t(f))) {
            [others addIndex:NSUInteger(f)];
        }
    }
    if (others.count > 0 && ![self setPriority:0 forFiles:others torrent:torrentID error:error]) return NO;
    uint8_t const own = std::clamp<uint8_t>(static_cast<uint8_t>(saved[std::size_t(fileIndex)]), 4, 6);
    if (![self setPriority:own forFiles:[NSIndexSet indexSetWithIndex:NSUInteger(fileIndex)] torrent:torrentID error:error]) {
        return NO;
    }
    h.set_flags(lt::torrent_flags::sequential_download);
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(key);
        if (it == _impl->entries.end()) return NO;
        it->second.streamingFile = int(fileIndex);
        it->second.streamingSavedPriorities = saved;
        it->second.streamingSavedSequential = savedSequential;
    }
    [self writeStreamingStateForID:key];
    [self updateStreamingWindowForID:key handle:h];
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    [self refreshStatusForID:torrentID handle:h];
    return YES;
}

/// Sidecar file: "<file> <sequential 0/1> <each file's priority, comma separated>".
- (void)writeStreamingStateForID:(std::string const &)torrentID {
    NSMutableString *text = [NSMutableString string];
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(torrentID);
        if (it == _impl->entries.end() || it->second.streamingFile < 0) return;
        [text appendFormat:@"%d %d ", it->second.streamingFile, it->second.streamingSavedSequential ? 1 : 0];
        for (std::size_t i = 0; i < it->second.streamingSavedPriorities.size(); ++i) {
            [text appendFormat:(i == 0 ? @"%d" : @",%d"), int(static_cast<std::uint8_t>(it->second.streamingSavedPriorities[i]))];
        }
    }
    [text writeToURL:[self streamingURLForID:torrentID] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (BOOL)stopDownloadingFromStartForTorrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:error]) return NO;
    [self endStreamingForID:torrentID.UTF8String handle:h];
    [self refreshStatusForID:torrentID handle:h];
    return YES;
}

- (void)endStreamingForID:(std::string const &)torrentID handle:(lt::torrent_handle const &)h {
    [self endStreamingForID:torrentID handle:h keepDeadlines:NO];
}

/// `keepDeadlines` leaves the last pieces of the file urgent while the other files resume.
- (void)endStreamingForID:(std::string const &)torrentID handle:(lt::torrent_handle const &)h keepDeadlines:(BOOL)keepDeadlines {
    std::vector<lt::download_priority_t> saved;
    bool savedSequential = false;
    bool wasStreaming = false;
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(torrentID);
        if (it != _impl->entries.end() && it->second.streamingFile >= 0) {
            wasStreaming = true;
            saved = std::move(it->second.streamingSavedPriorities);
            savedSequential = it->second.streamingSavedSequential;
            it->second.streamingFile = -1;
            it->second.streamingSavedPriorities.clear();
            it->second.streamingDeadlines.clear();
        }
    }
    if (!keepDeadlines) h.clear_piece_deadlines();
    [[NSFileManager defaultManager] removeItemAtURL:[self streamingURLForID:torrentID] error:nil];
    if (!wasStreaming) return;
    if (!savedSequential) h.unset_flags(lt::torrent_flags::sequential_download);
    // Every file gets its earlier priority back, which also drops the raised end pieces.
    // libtorrent ignores this once the torrent is complete, which is fine.
    std::map<std::uint8_t, NSMutableIndexSet *> byLevel;
    for (std::size_t f = 0; f < saved.size(); ++f) {
        auto const level = static_cast<std::uint8_t>(saved[f]);
        if (!byLevel[level]) byLevel[level] = [NSMutableIndexSet indexSet];
        [byLevel[level] addIndex:f];
    }
    for (auto const &[level, files] : byLevel) {
        [self setPriority:level forFiles:files torrent:@(torrentID.c_str()) error:nil];
    }
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(torrentID);
        if (it != _impl->entries.end()) {
            it->second.restoreCheck = saved;
            it->second.restoreCheckAt = Clock::now() + std::chrono::milliseconds(1500);
        }
    }
    h.save_resume_data(lt::torrent_handle::save_info_dict);
}

/// Keeps the file's end at priority 7 until it arrives, and ends download-from-start once the
/// file is complete. Called once per second, and when libtorrent confirms a file priority
/// change (which resets every piece priority).
- (void)updateStreamingWindowForID:(std::string const &)torrentID handle:(lt::torrent_handle const &)h {
    int file = -1;
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(torrentID);
        if (it != _impl->entries.end()) file = it->second.streamingFile;
    }
    if (file < 0) return;
    std::shared_ptr<lt::torrent_info const> ti = h.torrent_file();
    if (!ti) return;
    lt::file_storage const &fs = ti->layout();
    if (file >= fs.num_files()) {
        [self endStreamingForID:torrentID handle:h];
        return;
    }
    lt::file_index_t const f(file);
    lt::torrent_status const st = h.status(lt::torrent_handle::query_pieces);
    if (st.state == lt::torrent_status::checking_files || st.state == lt::torrent_status::checking_resume_data) return;
    TKFileReadiness const ready = TKReadiness(fs, f, st.pieces);
    if (ready.firstMissingPiece < 0) {
        [self endStreamingForID:torrentID handle:h]; // the whole file is here
        [self refreshStatusForID:@(torrentID.c_str()) handle:h];
        return;
    }
    auto const has = [&](int p) { return p < st.pieces.size() && st.pieces.get_bit(lt::piece_index_t(p)); };
    int const last = static_cast<int>(fs.map_file(f, fs.file_size(f) - 1, 1).piece);
    int const headPieces = int(std::clamp<std::int64_t>(kStreamingHeadBytes / std::max(1, fs.piece_length()),
                                                        kStreamingMinHeadPieces, kStreamingMaxHeadPieces));

    // Hand back to the other files once every missing piece of this one has a deadline. Waiting
    // until the file is complete would make the whole torrent "finished" (other files are paused),
    // and bringing files back at that moment sometimes left libtorrent stuck in that state.
    int missing = 0;
    for (int p = ready.firstMissingPiece; p <= last && missing <= headPieces; ++p) missing += has(p) ? 0 : 1;
    if (ready.hasEnd && missing <= headPieces) {
        [self endStreamingForID:torrentID handle:h keepDeadlines:YES];
        [self refreshStatusForID:@(torrentID.c_str()) handle:h];
        return;
    }

    // Deadlines on the next few missing pieces, each set once.
    std::vector<int> fresh;
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(torrentID);
        if (it == _impl->entries.end()) return;
        std::set<int> &given = it->second.streamingDeadlines;
        for (auto p = given.begin(); p != given.end();) p = has(*p) ? given.erase(p) : std::next(p);
        int added = 0;
        for (int p = ready.firstMissingPiece; p <= last && added < headPieces; ++p) {
            if (has(p)) continue;
            ++added;
            if (given.insert(p).second) fresh.push_back(p);
        }
        // The file's end too: as a plain priority-7 piece it can lose out to the deadlines above.
        int const endStart = static_cast<int>(fs.map_file(f, std::max<int64_t>(0, fs.file_size(f) - kFileEndBytes), 1).piece);
        for (int p = endStart; p <= last; ++p) {
            if (!has(p) && given.insert(p).second) fresh.push_back(p);
        }
    }
    for (std::size_t i = 0; i < fresh.size(); ++i) {
        h.set_piece_deadline(lt::piece_index_t(fresh[i]), 1000 + int(i) * 200);
    }

    if (ready.hasEnd) return;
    int const endStart = static_cast<int>(fs.map_file(f, std::max<int64_t>(0, fs.file_size(f) - kFileEndBytes), 1).piece);
    std::vector<lt::download_priority_t> const current = h.get_piece_priorities();
    std::vector<std::pair<lt::piece_index_t, lt::download_priority_t>> changes;
    for (int p = endStart; p <= last; ++p) {
        if (has(p)) continue;
        if (std::size_t(p) < current.size() && current[std::size_t(p)] == lt::top_priority) continue;
        changes.emplace_back(lt::piece_index_t(p), lt::top_priority);
    }
    if (!changes.empty()) h.prioritize_pieces(changes);
}

/// Raises pieces that stayed below the priority their files were restored to. Only raises, so
/// hand-set higher priorities and deadlines stay.
- (void)verifyRestoredPriorities {
    std::vector<std::tuple<std::string, lt::torrent_handle, std::vector<lt::download_priority_t>>> due;
    auto const now = Clock::now();
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        for (auto &[torrentID, entry] : _impl->entries) {
            if (entry.restoreCheck.empty() || now < entry.restoreCheckAt) continue;
            due.emplace_back(torrentID, entry.handle, std::move(entry.restoreCheck));
            entry.restoreCheck.clear();
        }
    }
    for (auto &[torrentID, h, files] : due) {
        try {
            std::shared_ptr<lt::torrent_info const> ti = h.torrent_file();
            if (!ti || h.status({}).is_seeding) continue;
            std::vector<lt::download_priority_t> const implied = TKPiecePrioritiesFromFiles(ti->layout(), files);
            std::vector<lt::download_priority_t> const current = h.get_piece_priorities();
            std::vector<std::pair<lt::piece_index_t, lt::download_priority_t>> raise;
            for (std::size_t p = 0; p < implied.size() && p < current.size(); ++p) {
                if (current[p] < implied[p]) raise.emplace_back(lt::piece_index_t(int(p)), implied[p]);
            }
            if (!raise.empty()) {
                os_log_info(TKLog(), "Raised %lu pieces left below their files' priority", raise.size());
                h.prioritize_pieces(raise);
                h.save_resume_data(lt::torrent_handle::save_info_dict);
                [self refreshStatusForID:@(torrentID.c_str()) handle:h];
            }
        } catch (std::exception const &e) {
            os_log_error(TKLog(), "Checking restored priorities failed: %{public}s", e.what());
        }
    }
}

- (void)updateStreamingWindows {
    std::vector<std::pair<std::string, lt::torrent_handle>> streaming;
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        for (auto const &[torrentID, entry] : _impl->entries) {
            if (entry.streamingFile >= 0) streaming.emplace_back(torrentID, entry.handle);
        }
    }
    for (auto const &[torrentID, handle] : streaming) {
        try {
            [self updateStreamingWindowForID:torrentID handle:handle];
        } catch (std::exception const &e) {
            os_log_error(TKLog(), "Updating download-from-start window failed: %{public}s", e.what());
        }
    }
}

- (BOOL)connectPeerWithHost:(NSString *)host port:(NSInteger)port toTorrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:error]) return NO;
    boost::system::error_code ec;
    auto address = boost::asio::ip::make_address(host.UTF8String ?: "", ec);
    if (ec || port <= 0 || port > 65535) {
        if (error) *error = TKMakeError(TKErrorInvalidArgument, @"Invalid peer address or port.");
        return NO;
    }
    h.connect_peer(lt::tcp::endpoint(address, static_cast<unsigned short>(port)));
    return YES;
}

// MARK: - Queries

- (NSArray<TKTorrentStatus *> *)orderedStatusesLocked {
    std::vector<std::pair<std::uint64_t, TKTorrentStatus *>> items;
    items.reserve(_impl->statuses.size());
    for (auto const &[torrentID, status] : _impl->statuses) {
        auto it = _impl->entries.find(torrentID);
        if (it != _impl->entries.end()) items.emplace_back(it->second.order, status);
    }
    std::sort(items.begin(), items.end(), [](auto const &a, auto const &b) { return a.first < b.first; });
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:items.size()];
    for (auto const &item : items) [result addObject:item.second];
    return result;
}

- (NSArray<TKTorrentStatus *> *)allTorrents {
    if (self.closed) return @[];
    std::lock_guard<std::mutex> lock(_impl->mutex);
    return [self orderedStatusesLocked];
}

- (nullable TKTorrentStatus *)statusForTorrent:(NSString *)torrentID {
    if (self.closed) return nil;
    std::lock_guard<std::mutex> lock(_impl->mutex);
    auto it = _impl->statuses.find(torrentID.UTF8String);
    return it == _impl->statuses.end() ? nil : it->second;
}

- (nullable NSArray<TKFileEntry *> *)filesForTorrent:(NSString *)torrentID {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:nil]) return nil;
    std::shared_ptr<lt::torrent_info const> ti = h.torrent_file();
    if (!ti) return nil;
    // layout() has the original names. Renamed files will be layered on top in a later phase.
    lt::file_storage const &fs = ti->layout();
    std::vector<std::int64_t> progress;
    h.file_progress(progress);
    std::vector<lt::download_priority_t> priorities = h.get_file_priorities();
    lt::typed_bitfield<lt::piece_index_t> const have = h.status(lt::torrent_handle::query_pieces).pieces;
    int streamingFile = -1;
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->entries.find(torrentID.UTF8String);
        if (it != _impl->entries.end()) streamingFile = it->second.streamingFile;
    }

    NSMutableArray *files = [NSMutableArray arrayWithCapacity:fs.num_files()];
    for (lt::file_index_t i : fs.file_range()) {
        if (fs.pad_file_at(i)) continue;
        auto const idx = static_cast<std::size_t>(static_cast<int>(i));
        int64_t const done = idx < progress.size() ? progress[idx] : 0;
        int const priority = idx < priorities.size() ? static_cast<int>(static_cast<std::uint8_t>(priorities[idx])) : 4;
        TKFileReadiness const ready = TKReadiness(fs, i, have);
        [files addObject:[[TKFileEntry alloc] initWithIndex:i storage:fs downloadedBytes:done priority:priority
                                            contiguousBytes:ready.contiguousBytes hasEnd:ready.hasEnd
                                         downloadsFromStart:static_cast<int>(i) == streamingFile]];
    }
    return files;
}

- (nullable TKPieceMap *)pieceMapForTorrent:(NSString *)torrentID {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:nil]) return nil;
    try {
        lt::torrent_status st = h.status(lt::torrent_handle::query_pieces | lt::torrent_handle::query_torrent_file);
        std::shared_ptr<lt::torrent_info const> ti = st.torrent_file.lock();
        if (!st.has_metadata || !ti) {
            return [[TKPieceMap alloc] initWithID:torrentID pieceLength:0 totalSize:0 fill:[NSData data]
                                       priorities:[NSData data] availability:[NSData data] tracksAvailability:NO];
        }
        int const count = ti->num_pieces();

        NSMutableData *fill = [NSMutableData dataWithLength:count];
        auto *fillBytes = static_cast<std::uint8_t *>(fill.mutableBytes);
        if (st.pieces.size() == count) {
            for (int i = 0; i < count; ++i) {
                if (st.pieces.get_bit(lt::piece_index_t(i))) fillBytes[i] = TKPieceFillHave;
            }
        }
        for (lt::partial_piece_info const &p : h.get_download_queue()) {
            int const i = static_cast<int>(p.piece_index);
            if (i < 0 || i >= count || fillBytes[i] == TKPieceFillHave || p.blocks_in_piece <= 0) continue;
            double const received = double(p.finished + p.writing) / double(p.blocks_in_piece);
            int const span = TKPieceFillDownloadingMax - TKPieceFillDownloadingMin;
            fillBytes[i] = static_cast<std::uint8_t>(TKPieceFillDownloadingMin + std::lround(std::clamp(received, 0.0, 1.0) * span));
        }

        NSMutableData *priorities = [NSMutableData dataWithLength:count];
        auto *priorityBytes = static_cast<std::uint8_t *>(priorities.mutableBytes);
        std::vector<lt::download_priority_t> const pp = h.get_piece_priorities();
        for (int i = 0; i < count; ++i) {
            priorityBytes[i] = i < int(pp.size()) ? static_cast<std::uint8_t>(pp[std::size_t(i)]) : 4;
        }

        bool const tracks = !st.is_seeding;
        NSMutableData *availability = [NSMutableData dataWithLength:count * sizeof(std::uint16_t)];
        if (tracks) {
            auto *availabilityValues = static_cast<std::uint16_t *>(availability.mutableBytes);
            std::vector<int> avail;
            h.piece_availability(avail);
            for (int i = 0; i < count && i < int(avail.size()); ++i) {
                availabilityValues[i] = static_cast<std::uint16_t>(std::clamp(avail[std::size_t(i)], 0, 0xffff));
            }
        }
        return [[TKPieceMap alloc] initWithID:torrentID pieceLength:ti->piece_length() totalSize:ti->total_size()
                                         fill:fill priorities:priorities availability:availability
                                  tracksAvailability:tracks];
    } catch (std::exception const &e) {
        os_log_error(TKLog(), "Piece map failed: %{public}s", e.what());
        return nil;
    }
}

// MARK: - Inspector

- (nullable NSArray<TKPeer *> *)peersForTorrent:(NSString *)torrentID {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:nil]) return nil;
    std::vector<lt::peer_info> peers;
    h.get_peer_info(peers);
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:peers.size()];
    for (lt::peer_info const &p : peers) {
        if (p.flags & (lt::peer_info::handshake | lt::peer_info::connecting)) continue; // not connected yet
        [result addObject:[[TKPeer alloc] initWithPeerInfo:p]];
    }
    return result;
}

- (nullable NSArray<TKTracker *> *)trackersForTorrent:(NSString *)torrentID {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:nil]) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (lt::announce_entry const &entry : h.trackers()) [result addObject:[[TKTracker alloc] initWithEntry:entry]];
    return result;
}

- (nullable TKTorrentDetails *)detailsForTorrent:(NSString *)torrentID {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:nil]) return nil;
    return [[TKTorrentDetails alloc] initWithID:torrentID handle:h];
}

- (BOOL)addTrackerURL:(NSString *)url toTorrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:error]) return NO;
    NSString *trimmed = [url stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *scheme = [NSURL URLWithString:trimmed].scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"udp"])) {
        if (error) *error = TKMakeError(TKErrorInvalidArgument, @"Tracker addresses start with http://, https:// or udp://.");
        return NO;
    }
    std::vector<lt::announce_entry> trackers = h.trackers();
    std::uint8_t tier = 0;
    for (auto const &t : trackers) {
        if (t.url == trimmed.UTF8String) {
            if (error) *error = TKMakeError(TKErrorInvalidArgument, @"This tracker is already in the list.");
            return NO;
        }
        tier = std::max<std::uint8_t>(tier, std::uint8_t(t.tier + 1));
    }
    lt::announce_entry entry(trimmed.UTF8String);
    entry.tier = tier;
    h.add_tracker(entry);
    h.force_reannounce(0, -1, lt::torrent_handle::ignore_min_interval);
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    return YES;
}

- (BOOL)removeTrackerURL:(NSString *)url fromTorrent:(NSString *)torrentID error:(NSError **)error {
    lt::torrent_handle h;
    if (![self handleForID:torrentID handle:&h error:error]) return NO;
    std::vector<lt::announce_entry> trackers = h.trackers();
    auto const before = trackers.size();
    std::string const target = url.UTF8String ?: "";
    trackers.erase(std::remove_if(trackers.begin(), trackers.end(), [&](auto const &t) { return t.url == target; }), trackers.end());
    if (trackers.size() == before) {
        if (error) *error = TKMakeError(TKErrorInvalidArgument, @"No such tracker.");
        return NO;
    }
    h.replace_trackers(trackers);
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    return YES;
}

// MARK: - Resume data

- (NSURL *)resumeURLForID:(std::string const &)torrentID {
    return [_stateDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"%s%s", torrentID.c_str(), kResumeExtension]];
}

/// Caller must hold the mutex.
- (void)writeResumeData:(lt::add_torrent_params const &)atp forID:(std::string const &)torrentID {
    std::vector<char> buf = lt::write_resume_data_buf(atp);
    NSData *data = [NSData dataWithBytes:buf.data() length:buf.size()];
    NSError *error = nil;
    if (![data writeToURL:[self resumeURLForID:torrentID] options:NSDataWritingAtomic error:&error]) {
        os_log_error(TKLog(), "Could not write resume data for %{public}s: %{public}@", torrentID.c_str(), error.localizedDescription);
    }
}

- (void)requestResumeData:(lt::resume_data_flags_t)flags {
    std::vector<lt::torrent_handle> handles;
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        for (auto const &[torrentID, entry] : _impl->entries) handles.push_back(entry.handle);
    }
    for (auto const &h : handles) h.save_resume_data(flags | lt::torrent_handle::save_info_dict);
}

- (void)saveResumeData {
    if (self.closed) return;
    [self requestResumeData:lt::torrent_handle::only_if_modified];
}

// MARK: - Alerts

/// Returns the torrent ID for an alert's handle, or empty if the torrent is gone.
- (std::string)idForHandle:(lt::torrent_handle const &)handle {
    std::lock_guard<std::mutex> lock(_impl->mutex);
    auto it = _impl->idsByHandle.find(handle.id());
    return it == _impl->idsByHandle.end() ? std::string() : it->second;
}

- (void)handleAlert:(lt::alert *)a {
    if (auto *su = lt::alert_cast<lt::state_update_alert>(a)) {
        NSArray<TKTorrentStatus *> *torrents;
        {
            std::lock_guard<std::mutex> lock(_impl->mutex);
            for (lt::torrent_status const &st : su->status) {
                auto idIt = _impl->idsByHandle.find(st.handle.id());
                if (idIt == _impl->idsByHandle.end()) continue;
                auto entryIt = _impl->entries.find(idIt->second);
                if (entryIt == _impl->entries.end()) continue;
                Entry const &entry = entryIt->second;
                _impl->statuses[idIt->second] = [[TKTorrentStatus alloc] initWithID:@(idIt->second.c_str()) status:st
                                                                      downloadLimit:entry.downloadLimit
                                                                        uploadLimit:entry.uploadLimit
                                                           fileDownloadingFromStart:entry.streamingFile];
            }
            torrents = [self orderedStatusesLocked];
        }
        TKSessionSnapshot *snapshot = [[TKSessionSnapshot alloc] initWithTorrents:torrents
                                                                         dhtNodes:_impl->dhtNodes.load()
                                                                       listenPort:_impl->listenPort.load()];
        void (^handler)(TKSessionSnapshot *) = self.snapshotHandler;
        if (handler) dispatch_async(_deliveryQueue, ^{ handler(snapshot); });
        return;
    }
    if (auto *ss = lt::alert_cast<lt::session_stats_alert>(a)) {
        if (_impl->dhtNodesMetric >= 0) _impl->dhtNodes = static_cast<long>(ss->counters()[_impl->dhtNodesMetric]);
        return;
    }
    if (auto *sr = lt::alert_cast<lt::save_resume_data_alert>(a)) {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->idsByHandle.find(sr->handle.id());
        if (it != _impl->idsByHandle.end()) [self writeResumeData:sr->params forID:it->second];
        return;
    }
    if (auto *ls = lt::alert_cast<lt::listen_succeeded_alert>(a)) {
        if (ls->socket_type == lt::socket_type_t::tcp) _impl->listenPort = ls->port;
        return;
    }
    if (auto *lf = lt::alert_cast<lt::listen_failed_alert>(a)) {
        [self deliverEvent:[[TKTorrentEvent alloc] initWithKind:TKTorrentEventKindSessionError torrentID:nil torrentName:nil
                                                        message:TKString(lf->message())]];
        return;
    }
    if (auto *md = lt::alert_cast<lt::metadata_received_alert>(a)) {
        md->handle.save_resume_data(lt::torrent_handle::save_info_dict);
        [self deliverTorrentEvent:TKTorrentEventKindMetadataReceived handle:md->handle message:nil];
        return;
    }
    if (auto *fin = lt::alert_cast<lt::torrent_finished_alert>(a)) {
        fin->handle.save_resume_data(lt::torrent_handle::save_info_dict);
        bool suppress = false;
        {
            std::lock_guard<std::mutex> lock(_impl->mutex);
            auto idIt = _impl->idsByHandle.find(fin->handle.id());
            auto entryIt = idIt == _impl->idsByHandle.end() ? _impl->entries.end() : _impl->entries.find(idIt->second);
            if (entryIt != _impl->entries.end()) {
                suppress = entryIt->second.suppressFinishedEvent;
                entryIt->second.suppressFinishedEvent = false;
            }
        }
        if (!suppress) [self deliverTorrentEvent:TKTorrentEventKindFinished handle:fin->handle message:nil];
        return;
    }
    if (auto *te = lt::alert_cast<lt::torrent_error_alert>(a)) {
        NSString *message = TKString(te->error.message());
        if (te->filename() && *te->filename()) message = [NSString stringWithFormat:@"%@ (%s)", message, te->filename()];
        [self deliverTorrentEvent:TKTorrentEventKindTorrentError handle:te->handle message:message];
        return;
    }
    if (auto *fe = lt::alert_cast<lt::file_error_alert>(a)) {
        NSString *message = [NSString stringWithFormat:@"%@: %s", TKString(fe->error.message()), fe->filename()];
        [self deliverTorrentEvent:TKTorrentEventKindTorrentError handle:fe->handle message:message];
        return;
    }
    if (auto *fp = lt::alert_cast<lt::file_prio_alert>(a)) {
        std::vector<std::pair<lt::piece_index_t, lt::download_priority_t>> restore;
        {
            std::lock_guard<std::mutex> lock(_impl->mutex);
            auto idIt = _impl->idsByHandle.find(fp->handle.id());
            auto entryIt = idIt == _impl->idsByHandle.end() ? _impl->entries.end() : _impl->entries.find(idIt->second);
            if (entryIt == _impl->entries.end()) return;
            Entry &entry = entryIt->second;
            for (auto const &[piece, prio] : entry.pieceRestore) restore.emplace_back(lt::piece_index_t(piece), prio);
            entry.pendingFilePriorityUpdates = std::max(0, entry.pendingFilePriorityUpdates - 1);
            if (entry.pendingFilePriorityUpdates == 0) entry.pieceRestore.clear();
        }
        if (!restore.empty()) {
            fp->handle.prioritize_pieces(restore);
            fp->handle.save_resume_data(lt::torrent_handle::save_info_dict);
        }
        std::string const torrentID = [self idForHandle:fp->handle];
        if (!torrentID.empty()) {
            [self updateStreamingWindowForID:torrentID handle:fp->handle];
            // A priority change alone may not mark the torrent as updated, so refresh its
            // status here; otherwise wanted bytes and state could stay stale without peers.
            [self refreshStatusForID:@(torrentID.c_str()) handle:fp->handle];
        }
        return;
    }
    if (auto *td = lt::alert_cast<lt::torrent_deleted_alert>(a)) {
        [self deliverDeleteEvent:td->info_hashes kind:TKTorrentEventKindFilesDeleted message:nil];
        return;
    }
    if (auto *tdf = lt::alert_cast<lt::torrent_delete_failed_alert>(a)) {
        [self deliverDeleteEvent:tdf->info_hashes kind:TKTorrentEventKindTorrentError
                         message:[NSString stringWithFormat:@"Could not delete files: %@", TKString(tdf->error.message())]];
        return;
    }
}

// MARK: - Event delivery

- (void)deliverEvent:(TKTorrentEvent *)event {
    void (^handler)(TKTorrentEvent *) = self.eventHandler;
    if (handler) dispatch_async(_deliveryQueue, ^{ handler(event); });
}

- (void)deliverTorrentEvent:(TKTorrentEventKind)kind handle:(lt::torrent_handle const &)handle message:(nullable NSString *)message {
    std::string const torrentID = [self idForHandle:handle];
    if (torrentID.empty()) return;
    NSString *idString = @(torrentID.c_str());
    TKTorrentStatus *status = [self statusForTorrent:idString];
    [self deliverEvent:[[TKTorrentEvent alloc] initWithKind:kind torrentID:idString torrentName:status.name message:message]];
}

- (void)deliverDeleteEvent:(lt::info_hash_t const &)hashes kind:(TKTorrentEventKind)kind message:(nullable NSString *)message {
    std::pair<std::string, std::string> info;
    {
        std::lock_guard<std::mutex> lock(_impl->mutex);
        auto it = _impl->pendingDeletes.find(TKHexID(hashes));
        if (it == _impl->pendingDeletes.end()) return;
        info = it->second;
        _impl->pendingDeletes.erase(it);
    }
    [self deliverEvent:[[TKTorrentEvent alloc] initWithKind:kind torrentID:@(info.first.c_str())
                                                torrentName:TKString(info.second) message:message]];
}

@end
