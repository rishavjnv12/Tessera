#import <TesseraKit/TKDefines.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TKTorrentState) {
    TKTorrentStateCheckingResumeData = 0,
    TKTorrentStateCheckingFiles,
    TKTorrentStateDownloadingMetadata,
    TKTorrentStateDownloading,
    /// All wanted files are complete, but some files are skipped.
    TKTorrentStateFinished,
    TKTorrentStateSeeding,
} NS_SWIFT_NAME(TorrentState);

/// Immutable point-in-time status of one torrent.
NS_SWIFT_NAME(TorrentStatus)
NS_SWIFT_SENDABLE
TK_EXPORT
@interface TKTorrentStatus : NSObject

/// Stable identifier: the hex info-hash the torrent was first added with.
@property (nonatomic, readonly, copy) NSString *torrentID NS_SWIFT_NAME(id);
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *savePath;
@property (nonatomic, readonly) TKTorrentState state;

/// Paused by the user.
@property (nonatomic, readonly, getter=isPaused) BOOL paused;
/// Waiting for a free slot because of the active download or seed limits.
@property (nonatomic, readonly, getter=isQueued) BOOL queued;
@property (nonatomic, readonly) BOOL hasMetadata;
/// Pieces are requested in order from the start of the torrent.
@property (nonatomic, readonly, getter=isSequential) BOOL sequential;
/// File being downloaded from its start (`TKFileEntry.index`), or -1.
@property (nonatomic, readonly) NSInteger fileDownloadingFromStart;

/// 0...1, of the bytes that are wanted (skipped files excluded).
@property (nonatomic, readonly) double progress;
/// Total size of all files. 0 until metadata is known.
@property (nonatomic, readonly) int64_t totalSize;
/// Bytes wanted after file priorities are applied.
@property (nonatomic, readonly) int64_t totalWanted;
/// Wanted bytes already downloaded and verified.
@property (nonatomic, readonly) int64_t totalWantedDone;
/// All-time payload bytes downloaded and uploaded.
@property (nonatomic, readonly) int64_t totalDownloaded;
@property (nonatomic, readonly) int64_t totalUploaded;
/// All-time upload divided by all-time download. 0 when nothing was downloaded.
@property (nonatomic, readonly) double ratio;

/// Payload bytes per second.
@property (nonatomic, readonly) int64_t downloadRate;
@property (nonatomic, readonly) int64_t uploadRate;
/// Per-torrent limits in bytes per second. 0 means unlimited.
@property (nonatomic, readonly) int64_t downloadLimit;
@property (nonatomic, readonly) int64_t uploadLimit;

/// Peers currently connected, and how many of them are seeds.
@property (nonatomic, readonly) NSInteger connectedPeers;
@property (nonatomic, readonly) NSInteger connectedSeeds;
/// Swarm size reported by trackers. -1 when unknown.
@property (nonatomic, readonly) NSInteger swarmSeeds;
@property (nonatomic, readonly) NSInteger swarmLeechers;

/// 0 until metadata is known.
@property (nonatomic, readonly) NSInteger numPieces;
@property (nonatomic, readonly) NSInteger pieceLength;

/// Seconds until the wanted bytes are done. -1 when unknown or not downloading.
@property (nonatomic, readonly) NSTimeInterval eta;
@property (nonatomic, readonly, nullable) NSDate *addedDate;
@property (nonatomic, readonly, nullable) NSDate *completedDate;
/// Set when the torrent stopped because of an error.
@property (nonatomic, readonly, copy, nullable) NSString *errorMessage;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
