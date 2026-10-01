#import "TKInternal.h"

#include <libtorrent/alert.hpp>
#include <libtorrent/info_hash.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/version.hpp>

#include <algorithm>
#include <climits>

NSErrorDomain const TKErrorDomain = @"io.github.rishavjnv12.TesseraKit";

NSError *TKMakeError(TKErrorCode code, NSString *message) {
    return [NSError errorWithDomain:TKErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

NSString *TKString(std::string const &s) {
    NSString *str = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    // Torrent names are not always valid UTF-8. Fall back to Latin-1 rather than dropping them.
    return str ?: [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSISOLatin1StringEncoding] ?: @"";
}

std::string TKHexID(lt::info_hash_t const &hashes) {
    static char const digits[] = "0123456789abcdef";
    lt::sha1_hash const best = hashes.get_best();
    std::string out;
    out.reserve(40);
    for (auto const byte : best) {
        auto const b = static_cast<unsigned char>(byte);
        out.push_back(digits[b >> 4]);
        out.push_back(digits[b & 0xf]);
    }
    return out;
}

static int TKClampLimit(int64_t v) {
    return static_cast<int>(std::clamp<int64_t>(v, 0, INT_MAX));
}

lt::settings_pack TKSettingsPack(TKSessionSettings *s) {
    lt::settings_pack pack;
    std::string interfaces;
    if (s.listenInterfaces.length > 0) {
        interfaces = s.listenInterfaces.UTF8String;
    } else if (s.listenPort >= 0) {
        std::string const port = std::to_string(s.listenPort);
        interfaces = "0.0.0.0:" + port + ",[::]:" + port;
    }
    pack.set_str(lt::settings_pack::listen_interfaces, interfaces);
    pack.set_int(lt::settings_pack::download_rate_limit, TKClampLimit(s.downloadRateLimit));
    pack.set_int(lt::settings_pack::upload_rate_limit, TKClampLimit(s.uploadRateLimit));
    if (s.maxConnections > 0) {
        pack.set_int(lt::settings_pack::connections_limit, static_cast<int>(s.maxConnections));
    }
    pack.set_int(lt::settings_pack::active_downloads, static_cast<int>(s.activeDownloads));
    pack.set_int(lt::settings_pack::active_seeds, static_cast<int>(s.activeSeeds));
    pack.set_bool(lt::settings_pack::enable_dht, s.enableDHT);
    pack.set_bool(lt::settings_pack::enable_lsd, s.enableLSD);
    pack.set_bool(lt::settings_pack::enable_upnp, s.enableUPnP);
    pack.set_bool(lt::settings_pack::enable_natpmp, s.enableNATPMP);
    pack.set_str(lt::settings_pack::user_agent, std::string("Tessera/1.0 libtorrent/") + lt::version());
    lt::alert_category_t mask = lt::alert_category::error | lt::alert_category::status | lt::alert_category::storage;
    pack.set_int(lt::settings_pack::alert_mask, mask);
    // Keep shutdown quick: do not wait long for trackers to acknowledge "stopped".
    pack.set_int(lt::settings_pack::stop_tracker_timeout, 1);
    // HTTP web seeds get requests of at most 2 MiB instead of 16 MiB, so an urgent piece is not
    // stuck behind a large response (it held up download-from-start in testing).
    pack.set_int(lt::settings_pack::urlseed_max_request_bytes, 2 * 1024 * 1024);
    return pack;
}

// MARK: - TKSessionSettings

@implementation TKSessionSettings

- (instancetype)init {
    if ((self = [super init])) {
        _listenPort = 0;
        _activeDownloads = 3;
        _activeSeeds = 5;
        _enableDHT = YES;
        _enableLSD = YES;
        _enablePEX = YES;
        _enableUPnP = YES;
        _enableNATPMP = YES;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    TKSessionSettings *c = [[TKSessionSettings allocWithZone:zone] init];
    c.listenPort = _listenPort;
    c.listenInterfaces = _listenInterfaces;
    c.downloadRateLimit = _downloadRateLimit;
    c.uploadRateLimit = _uploadRateLimit;
    c.maxConnections = _maxConnections;
    c.activeDownloads = _activeDownloads;
    c.activeSeeds = _activeSeeds;
    c.enableDHT = _enableDHT;
    c.enableLSD = _enableLSD;
    c.enablePEX = _enablePEX;
    c.enableUPnP = _enableUPnP;
    c.enableNATPMP = _enableNATPMP;
    return c;
}

@end

// MARK: - TKAddTorrentOptions

@implementation TKAddTorrentOptions

- (id)copyWithZone:(NSZone *)zone {
    TKAddTorrentOptions *c = [[TKAddTorrentOptions allocWithZone:zone] init];
    c.savePath = _savePath;
    c.startPaused = _startPaused;
    c.filePriorities = _filePriorities;
    return c;
}

@end

// MARK: - TKTorrentStatus

@implementation TKTorrentStatus

static TKTorrentState TKMapState(lt::torrent_status::state_t state) {
    switch (state) {
        case lt::torrent_status::checking_files: return TKTorrentStateCheckingFiles;
        case lt::torrent_status::downloading_metadata: return TKTorrentStateDownloadingMetadata;
        case lt::torrent_status::downloading: return TKTorrentStateDownloading;
        case lt::torrent_status::finished: return TKTorrentStateFinished;
        case lt::torrent_status::seeding: return TKTorrentStateSeeding;
        case lt::torrent_status::checking_resume_data:
        default: return TKTorrentStateCheckingResumeData;
    }
}

- (instancetype)initWithID:(NSString *)torrentID
                    status:(lt::torrent_status const &)st
             downloadLimit:(int64_t)downloadLimit
               uploadLimit:(int64_t)uploadLimit
    fileDownloadingFromStart:(NSInteger)streamingFile {
    if ((self = [super init])) {
        bool const paused = static_cast<bool>(st.flags & lt::torrent_flags::paused);
        bool const autoManaged = static_cast<bool>(st.flags & lt::torrent_flags::auto_managed);

        _torrentID = [torrentID copy];
        _name = st.name.empty() ? [torrentID copy] : TKString(st.name);
        _savePath = TKString(st.save_path);
        _state = TKMapState(st.state);
        _paused = paused && !autoManaged;
        _queued = paused && autoManaged;
        _hasMetadata = st.has_metadata;
        _sequential = static_cast<bool>(st.flags & lt::torrent_flags::sequential_download);
        _fileDownloadingFromStart = streamingFile;
        _progress = st.progress;
        _totalWanted = st.total_wanted;
        _totalWantedDone = st.total_wanted_done;
        _totalDownloaded = st.all_time_download;
        _totalUploaded = st.all_time_upload;
        _ratio = st.all_time_download > 0 ? double(st.all_time_upload) / double(st.all_time_download) : 0;
        _downloadRate = st.download_payload_rate;
        _uploadRate = st.upload_payload_rate;
        _downloadLimit = downloadLimit;
        _uploadLimit = uploadLimit;
        _connectedPeers = st.num_peers;
        _connectedSeeds = st.num_seeds;
        _swarmSeeds = st.num_complete;
        _swarmLeechers = st.num_incomplete;
        if (auto ti = st.torrent_file.lock()) {
            _totalSize = ti->total_size();
            _numPieces = ti->num_pieces();
            _pieceLength = ti->piece_length();
        }
        _addedDate = st.added_time > 0 ? [NSDate dateWithTimeIntervalSince1970:st.added_time] : nil;
        _completedDate = st.completed_time > 0 ? [NSDate dateWithTimeIntervalSince1970:st.completed_time] : nil;
        if (st.errc) {
            _errorMessage = TKString(st.errc.message());
        }

        int64_t const remaining = st.total_wanted - st.total_wanted_done;
        bool const active = !paused && (st.state == lt::torrent_status::downloading);
        _eta = (active && st.download_payload_rate > 0 && remaining > 0)
            ? double(remaining) / double(st.download_payload_rate)
            : -1;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<TKTorrentStatus %@ \"%@\" state=%ld progress=%.3f>",
            _torrentID, _name, (long)_state, _progress];
}

@end

// MARK: - TKFileEntry

@implementation TKFileEntry

- (instancetype)initWithIndex:(lt::file_index_t)index
                      storage:(lt::file_storage const &)fs
              downloadedBytes:(int64_t)downloadedBytes
                     priority:(int)priority
              contiguousBytes:(int64_t)contiguousBytes
                       hasEnd:(BOOL)hasEnd
           downloadsFromStart:(BOOL)downloadsFromStart {
    if ((self = [super init])) {
        _index = static_cast<int>(index);
        _path = TKString(fs.file_path(index));
        _name = TKString(std::string(fs.file_name(index)));
        _size = fs.file_size(index);
        _offset = fs.file_offset(index);
        if (_size > 0) {
            _firstPiece = static_cast<int>(fs.map_file(index, 0, 1).piece);
            _lastPiece = static_cast<int>(fs.map_file(index, _size - 1, 1).piece);
        } else {
            _firstPiece = -1;
            _lastPiece = -1;
        }
        _downloadedBytes = downloadedBytes;
        _progress = _size > 0 ? double(downloadedBytes) / double(_size) : 1.0;
        _priority = priority;
        _contiguousBytes = contiguousBytes;
        _hasEnd = hasEnd;
        _downloadsFromStart = downloadsFromStart;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<TKFileEntry #%ld %@ %lld bytes pieces %ld-%ld>",
            (long)_index, _path, _size, (long)_firstPiece, (long)_lastPiece];
}

@end

// MARK: - TKPieceMap

@implementation TKPieceMap

- (instancetype)initWithID:(NSString *)torrentID
               pieceLength:(NSInteger)pieceLength
                 totalSize:(int64_t)totalSize
                      fill:(NSData *)fill
                priorities:(NSData *)priorities
              availability:(NSData *)availability
        tracksAvailability:(BOOL)tracksAvailability {
    if ((self = [super init])) {
        _torrentID = [torrentID copy];
        _pieceCount = static_cast<NSInteger>(fill.length);
        _pieceLength = pieceLength;
        _totalSize = totalSize;
        _fill = [fill copy];
        _priorities = [priorities copy];
        _availability = [availability copy];
        _tracksAvailability = tracksAvailability;
    }
    return self;
}

@end

// MARK: - TKSessionSnapshot

@implementation TKSessionSnapshot

- (instancetype)initWithTorrents:(NSArray<TKTorrentStatus *> *)torrents
                        dhtNodes:(NSInteger)dhtNodes
                      listenPort:(NSInteger)listenPort {
    if ((self = [super init])) {
        _torrents = [torrents copy];
        int64_t down = 0, up = 0;
        for (TKTorrentStatus *t in torrents) {
            down += t.downloadRate;
            up += t.uploadRate;
        }
        _downloadRate = down;
        _uploadRate = up;
        _dhtNodes = dhtNodes;
        _listenPort = listenPort;
        _date = [NSDate date];
    }
    return self;
}

@end

// MARK: - TKTorrentEvent

@implementation TKTorrentEvent

- (instancetype)initWithKind:(TKTorrentEventKind)kind
                   torrentID:(nullable NSString *)torrentID
                 torrentName:(nullable NSString *)torrentName
                     message:(nullable NSString *)message {
    if ((self = [super init])) {
        _kind = kind;
        _torrentID = [torrentID copy];
        _torrentName = [torrentName copy];
        _message = [message copy];
        _date = [NSDate date];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<TKTorrentEvent kind=%ld %@ %@>", (long)_kind, _torrentName ?: @"", _message ?: @""];
}

@end
