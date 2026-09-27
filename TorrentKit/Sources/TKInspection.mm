#import "TKInternal.h"

#include <libtorrent/announce_entry.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>

#include <algorithm>
#include <chrono>

// MARK: - Helpers

template <typename Digest>
static NSString *TKHex(Digest const &digest) {
    static char const digits[] = "0123456789abcdef";
    std::string out;
    out.reserve(digest.size() * 2);
    for (auto const byte : digest) {
        auto const b = static_cast<unsigned char>(byte);
        out.push_back(digits[b >> 4]);
        out.push_back(digits[b & 0xf]);
    }
    return @(out.c_str());
}

static NSString *TKEndpointString(lt::tcp::endpoint const &ep) {
    std::string const address = ep.address().to_string();
    return ep.address().is_v6() ? [NSString stringWithFormat:@"[%s]:%u", address.c_str(), ep.port()]
                                : [NSString stringWithFormat:@"%s:%u", address.c_str(), ep.port()];
}

// MARK: - TKPeer

@implementation TKPeer

- (instancetype)initWithPeerInfo:(lt::peer_info const &)p {
    if ((self = [super init])) {
        _address = TKEndpointString(p.remote_endpoint());
        _client = TKString(p.client);
        _downloadRate = p.payload_down_speed;
        _uploadRate = p.payload_up_speed;
        _totalDownloaded = p.total_download;
        _totalUploaded = p.total_upload;
        _progress = std::clamp(double(p.progress), 0.0, 1.0);
        _seed = static_cast<bool>(p.flags & lt::peer_info::seed);
        _incoming = !static_cast<bool>(p.flags & lt::peer_info::outgoing_connection);
        _encrypted = static_cast<bool>(p.flags & (lt::peer_info::rc4_encrypted | lt::peer_info::plaintext_encrypted));
        _utp = static_cast<bool>(p.flags & lt::peer_info::utp_socket);
        _webSeed = static_cast<bool>(p.connection_type & (lt::peer_info::web_seed | lt::peer_info::http_seed));
        TKPeerSource source = 0;
        if (p.source & lt::peer_info::tracker) source |= TKPeerSourceTracker;
        if (p.source & lt::peer_info::dht) source |= TKPeerSourceDHT;
        if (p.source & lt::peer_info::pex) source |= TKPeerSourcePEX;
        if (p.source & lt::peer_info::lsd) source |= TKPeerSourceLSD;
        if (p.source & lt::peer_info::resume_data) source |= TKPeerSourceResumeData;
        if (p.source & lt::peer_info::incoming) source |= TKPeerSourceIncoming;
        _source = source;
    }
    return self;
}

@end

// MARK: - TKTracker

@implementation TKTracker

- (instancetype)initWithEntry:(lt::announce_entry const &)entry {
    if ((self = [super init])) {
        _url = TKString(entry.url);
        _tier = entry.tier;
        _seeds = -1;
        _peers = -1;
        _downloaded = -1;
        bool updating = false, working = false, failed = false;
        std::string message;
        auto next = lt::time_point32::max();
        for (lt::announce_endpoint const &endpoint : entry.endpoints) {
            for (lt::announce_infohash const &ih : endpoint.info_hashes) {
                updating = updating || ih.updating;
                if (ih.last_error) {
                    failed = true;
                    message = ih.message.empty() ? ih.last_error.message() : ih.message;
                } else if (ih.start_sent || ih.scrape_complete >= 0) {
                    working = true;
                    if (!ih.message.empty() && message.empty()) message = ih.message;
                }
                _seeds = std::max<NSInteger>(_seeds, ih.scrape_complete);
                _peers = std::max<NSInteger>(_peers, ih.scrape_incomplete);
                _downloaded = std::max<NSInteger>(_downloaded, ih.scrape_downloaded);
                if (ih.next_announce > (lt::time_point32::min)()) next = std::min(next, ih.next_announce);
            }
        }
        _status = updating ? TKTrackerStatusUpdating
            : working ? TKTrackerStatusWorking
            : failed ? TKTrackerStatusError
            : TKTrackerStatusNotContacted;
        _message = TKString(message);
        if (next != lt::time_point32::max()) {
            auto const seconds = std::chrono::duration_cast<std::chrono::seconds>(next - lt::clock_type::now()).count();
            _nextAnnounce = [NSDate dateWithTimeIntervalSinceNow:std::max<long long>(0, seconds)];
        }
    }
    return self;
}

@end

// MARK: - TKTorrentDetails

@implementation TKTorrentDetails

- (instancetype)initWithID:(NSString *)torrentID handle:(lt::torrent_handle const &)h {
    if ((self = [super init])) {
        _torrentID = [torrentID copy];
        lt::torrent_status const st = h.status(lt::torrent_handle::query_name);
        lt::info_hash_t const hashes = h.info_hashes();
        _infoHashV1 = hashes.has_v1() ? TKHex(hashes.v1) : nil;
        _infoHashV2 = hashes.has_v2() ? TKHex(hashes.v2) : nil;
        // libtorrent 2.1 keeps comment, creator and creation date with the add parameters.
        lt::add_torrent_params const atp = h.get_resume_data();
        _magnetLink = TKString(lt::make_magnet_uri(atp));
        _name = st.name.empty() ? [torrentID copy] : TKString(st.name);
        _comment = TKString(atp.comment);
        _creator = TKString(atp.created_by);
        _creationDate = atp.creation_date > 0 ? [NSDate dateWithTimeIntervalSince1970:atp.creation_date] : nil;
        if (std::shared_ptr<lt::torrent_info const> ti = h.torrent_file()) {
            _hasMetadata = YES;
            _privateTorrent = ti->priv();
            _totalSize = ti->total_size();
            _pieceLength = ti->piece_length();
            _numPieces = ti->num_pieces();
            lt::file_storage const &fs = ti->layout();
            NSInteger files = 0;
            for (lt::file_index_t f : fs.file_range()) files += fs.pad_file_at(f) ? 0 : 1;
            _fileCount = files;
        }
    }
    return self;
}

@end

// MARK: - TKTorrentPreview

@implementation TKTorrentPreviewFile

- (instancetype)initWithIndex:(NSInteger)index path:(NSString *)path name:(NSString *)name size:(int64_t)size {
    if ((self = [super init])) {
        _index = index;
        _path = [path copy];
        _name = [name copy];
        _size = size;
    }
    return self;
}

@end

@implementation TKTorrentPreview

- (instancetype)initWithID:(NSString *)torrentID name:(NSString *)name totalSize:(int64_t)totalSize
                     files:(NSArray<TKTorrentPreviewFile *> *)files privateTorrent:(BOOL)priv
                   comment:(NSString *)comment isMagnet:(BOOL)isMagnet {
    if ((self = [super init])) {
        _torrentID = [torrentID copy];
        _name = [name copy];
        _totalSize = totalSize;
        _files = [files copy];
        _privateTorrent = priv;
        _comment = [comment copy];
        _isMagnet = isMagnet;
    }
    return self;
}

+ (nullable instancetype)previewWithData:(NSData *)data error:(NSError **)error {
    try {
        lt::error_code ec;
        lt::bdecode_node node = lt::bdecode({static_cast<char const *>(data.bytes), static_cast<long>(data.length)}, ec);
        if (ec) throw lt::system_error(ec);
        lt::add_torrent_params atp = lt::load_torrent_parsed(node);
        if (!atp.ti) throw std::runtime_error("no metadata");
        lt::file_storage const &fs = atp.ti->layout();
        NSMutableArray *files = [NSMutableArray array];
        for (lt::file_index_t f : fs.file_range()) {
            if (fs.pad_file_at(f)) continue;
            [files addObject:[[TKTorrentPreviewFile alloc] initWithIndex:static_cast<int>(f)
                                                                    path:TKString(fs.file_path(f))
                                                                    name:TKString(std::string(fs.file_name(f)))
                                                                    size:fs.file_size(f)]];
        }
        return [[TKTorrentPreview alloc] initWithID:@(TKHexID(atp.ti->info_hashes()).c_str())
                                               name:TKString(atp.ti->name())
                                          totalSize:atp.ti->total_size()
                                              files:files
                                     privateTorrent:atp.ti->priv()
                                            comment:TKString(atp.comment)
                                           isMagnet:NO];
    } catch (std::exception const &e) {
        if (error) *error = TKMakeError(TKErrorInvalidTorrent, [NSString stringWithFormat:@"Not a valid torrent: %s", e.what()]);
        return nil;
    }
}

+ (nullable instancetype)previewWithMagnetLink:(NSString *)link error:(NSError **)error {
    lt::error_code ec;
    lt::add_torrent_params atp = lt::parse_magnet_uri(link.UTF8String ?: "", ec);
    if (ec) {
        if (error) *error = TKMakeError(TKErrorInvalidMagnet, [NSString stringWithFormat:@"Not a valid magnet link: %s", ec.message().c_str()]);
        return nil;
    }
    NSString *torrentID = @(TKHexID(atp.info_hashes).c_str());
    return [[TKTorrentPreview alloc] initWithID:torrentID
                                           name:atp.name.empty() ? torrentID : TKString(atp.name)
                                      totalSize:0
                                          files:@[]
                                 privateTorrent:NO
                                        comment:@""
                                       isMagnet:YES];
}

@end
