#import <TesseraKit/TKDefines.h>

@class TKAddTorrentOptions;
@class TKFileEntry;
@class TKPieceMap;
@class TKPeer;
@class TKTracker;
@class TKTorrentDetails;
@class TKSessionSettings;
@class TKSessionSnapshot;
@class TKTorrentEvent;
@class TKTorrentStatus;

NS_ASSUME_NONNULL_BEGIN

/// A running libtorrent session. Thread-safe: every method can be called from any thread.
///
/// Torrents and their progress are stored in `stateDirectory` and restored automatically
/// the next time a session is created with the same directory. Call `shutdown` before
/// quitting so the latest progress is saved. Progress is also saved every 30 seconds and
/// on important changes, so a crash loses at most a few seconds of bookkeeping.
NS_SWIFT_NAME(TorrentSession)
NS_SWIFT_SENDABLE
TK_EXPORT
@interface TKSession : NSObject

/// Starts a session and restores the torrents saved in `stateDirectory`.
/// Both directories are created if missing.
- (nullable instancetype)initWithStateDirectory:(NSURL *)stateDirectory
                                defaultSavePath:(NSURL *)defaultSavePath
                                       settings:(TKSessionSettings *)settings
                                          error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSURL *stateDirectory;
@property (nonatomic, readonly, copy) NSURL *defaultSavePath;
@property (atomic, readonly, copy) TKSessionSettings *settings;
/// Port the session currently listens on. 0 when not listening.
@property (nonatomic, readonly) NSInteger listenPort;
@property (atomic, readonly, getter=isClosed) BOOL closed;

/// Called about once per second on a private background queue.
@property (atomic, copy, nullable) void (^snapshotHandler)(TKSessionSnapshot *snapshot);
/// Called on a private background queue.
@property (atomic, copy, nullable) void (^eventHandler)(TKTorrentEvent *event);
/// Called once on the same queue after `shutdown`, once earlier snapshots and events are delivered.
@property (atomic, copy, nullable) void (^closeHandler)(void);

- (void)applySettings:(TKSessionSettings *)settings;

// MARK: Adding and removing

/// Returns the new torrent's ID.
- (nullable NSString *)addTorrentFileAtURL:(NSURL *)url
                                   options:(nullable TKAddTorrentOptions *)options
                                     error:(NSError **)error NS_SWIFT_NAME(addTorrent(fileAt:options:));

- (nullable NSString *)addTorrentData:(NSData *)data
                              options:(nullable TKAddTorrentOptions *)options
                                error:(NSError **)error NS_SWIFT_NAME(addTorrent(data:options:));

- (nullable NSString *)addMagnetLink:(NSString *)magnetLink
                             options:(nullable TKAddTorrentOptions *)options
                               error:(NSError **)error NS_SWIFT_NAME(addMagnet(_:options:));

- (BOOL)removeTorrent:(NSString *)torrentID
          deleteFiles:(BOOL)deleteFiles
                error:(NSError **)error NS_SWIFT_NAME(removeTorrent(_:deleteFiles:));

// MARK: Control

- (BOOL)pauseTorrent:(NSString *)torrentID error:(NSError **)error NS_SWIFT_NAME(pauseTorrent(_:));
- (BOOL)resumeTorrent:(NSString *)torrentID error:(NSError **)error NS_SWIFT_NAME(resumeTorrent(_:));
/// Re-verifies all downloaded data against the piece hashes.
- (BOOL)recheckTorrent:(NSString *)torrentID error:(NSError **)error NS_SWIFT_NAME(recheckTorrent(_:));

/// Per-torrent limits in bytes per second. 0 means unlimited.
- (BOOL)setDownloadLimit:(int64_t)downloadLimit
             uploadLimit:(int64_t)uploadLimit
              forTorrent:(NSString *)torrentID
                   error:(NSError **)error NS_SWIFT_NAME(setLimits(download:upload:torrent:));

// MARK: Priorities
//
// Levels follow libtorrent: 0 skip (don't download), 1 lowest, 4 normal, 7 highest.
// Higher-priority pieces are requested first. Setting a file's priority also resets the
// hand-set priority of pieces inside that file; hand-set priorities elsewhere are kept.

/// Sets the priority of files by their `TKFileEntry.index`.
- (BOOL)setPriority:(uint8_t)priority
           forFiles:(NSIndexSet *)files
            torrent:(NSString *)torrentID
              error:(NSError **)error NS_SWIFT_NAME(setPriority(_:forFiles:torrent:));

/// Sets the priority of a contiguous run of pieces.
- (BOOL)setPriority:(uint8_t)priority
      forPieceRange:(NSRange)pieces
            torrent:(NSString *)torrentID
              error:(NSError **)error NS_SWIFT_NAME(setPriority(_:forPieceRange:torrent:));

// MARK: Download order

/// Requests pieces in order from the start of the torrent instead of rarest first.
- (BOOL)setSequential:(BOOL)sequential
           forTorrent:(NSString *)torrentID
                error:(NSError **)error NS_SWIFT_NAME(setSequential(_:torrent:));

/// Downloads one file first and in order from its start, so it can be opened early.
/// Other files of the torrent pause, the torrent switches to sequential order, and the file's
/// last megabyte is fetched early (many video formats keep their index there). One file per
/// torrent at a time. Ends by itself once the file is complete; every file's priority and the
/// sequential setting then return to what they were. Survives a restart.
- (BOOL)downloadFileFromStart:(NSInteger)fileIndex
                      torrent:(NSString *)torrentID
                        error:(NSError **)error NS_SWIFT_NAME(downloadFromStart(file:torrent:));

- (BOOL)stopDownloadingFromStartForTorrent:(NSString *)torrentID
                                     error:(NSError **)error NS_SWIFT_NAME(stopDownloadingFromStart(torrent:));

/// Connects directly to a known peer, e.g. "192.168.1.20" and 6881.
- (BOOL)connectPeerWithHost:(NSString *)host
                       port:(NSInteger)port
                  toTorrent:(NSString *)torrentID
                      error:(NSError **)error NS_SWIFT_NAME(connectPeer(host:port:torrent:));

// MARK: Queries

- (NSArray<TKTorrentStatus *> *)allTorrents;
- (nullable TKTorrentStatus *)statusForTorrent:(NSString *)torrentID NS_SWIFT_NAME(status(of:));
/// nil when the torrent is unknown or its metadata has not arrived yet.
/// Pad files used internally by some torrents are left out.
- (nullable NSArray<TKFileEntry *> *)filesForTorrent:(NSString *)torrentID NS_SWIFT_NAME(files(of:));
/// Current state of every piece. nil when the torrent is unknown. Makes several blocking
/// calls into libtorrent, so call it off the main thread, about once per second.
- (nullable TKPieceMap *)pieceMapForTorrent:(NSString *)torrentID NS_SWIFT_NAME(pieces(of:));

// MARK: Inspector

/// Connected peers, including web seeds. nil when the torrent is unknown.
- (nullable NSArray<TKPeer *> *)peersForTorrent:(NSString *)torrentID NS_SWIFT_NAME(peers(of:));
- (nullable NSArray<TKTracker *> *)trackersForTorrent:(NSString *)torrentID NS_SWIFT_NAME(trackers(of:));
- (nullable TKTorrentDetails *)detailsForTorrent:(NSString *)torrentID NS_SWIFT_NAME(details(of:));

/// Adds a tracker URL (http, https or udp) in a new tier after the existing ones.
- (BOOL)addTrackerURL:(NSString *)url toTorrent:(NSString *)torrentID error:(NSError **)error NS_SWIFT_NAME(addTracker(_:torrent:));
- (BOOL)removeTrackerURL:(NSString *)url fromTorrent:(NSString *)torrentID error:(NSError **)error NS_SWIFT_NAME(removeTracker(_:torrent:));

// MARK: Persistence and lifecycle

/// Saves progress for every torrent that changed since the last save.
- (void)saveResumeData;

/// Saves all progress and the DHT state, then stops the session.
/// Blocks for up to a few seconds. The session cannot be used afterwards.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
