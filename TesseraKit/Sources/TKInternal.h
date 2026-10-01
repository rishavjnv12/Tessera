// Private to TesseraKit. Objective-C++ only.
#pragma once

#import <TesseraKit/TesseraKit.h>

#include <libtorrent/announce_entry.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_status.hpp>

#include <string>
#include <vector>

namespace lt = libtorrent;

NS_ASSUME_NONNULL_BEGIN

NSError *TKMakeError(TKErrorCode code, NSString *message);
NSString *TKString(std::string const &s);
/// 40-character lowercase hex of the best available info-hash (v2 truncated, else v1).
std::string TKHexID(lt::info_hash_t const &hashes);
lt::settings_pack TKSettingsPack(TKSessionSettings *settings);

@interface TKTorrentStatus ()
- (instancetype)initWithID:(NSString *)torrentID
                    status:(lt::torrent_status const &)status
             downloadLimit:(int64_t)downloadLimit
               uploadLimit:(int64_t)uploadLimit
    fileDownloadingFromStart:(NSInteger)streamingFile;
@end

@interface TKFileEntry ()
- (instancetype)initWithIndex:(lt::file_index_t)index
                      storage:(lt::file_storage const &)storage
              downloadedBytes:(int64_t)downloadedBytes
                     priority:(int)priority
              contiguousBytes:(int64_t)contiguousBytes
                       hasEnd:(BOOL)hasEnd
           downloadsFromStart:(BOOL)downloadsFromStart;
@end

@interface TKPeer ()
- (instancetype)initWithPeerInfo:(lt::peer_info const &)info;
@end

@interface TKTracker ()
- (instancetype)initWithEntry:(lt::announce_entry const &)entry;
@end

@interface TKTorrentDetails ()
- (instancetype)initWithID:(NSString *)torrentID handle:(lt::torrent_handle const &)handle;
@end

@interface TKSessionSnapshot ()
- (instancetype)initWithTorrents:(NSArray<TKTorrentStatus *> *)torrents
                        dhtNodes:(NSInteger)dhtNodes
                      listenPort:(NSInteger)listenPort;
@end

@interface TKTorrentEvent ()
- (instancetype)initWithKind:(TKTorrentEventKind)kind
                   torrentID:(nullable NSString *)torrentID
                 torrentName:(nullable NSString *)torrentName
                     message:(nullable NSString *)message;
@end

NS_ASSUME_NONNULL_END
