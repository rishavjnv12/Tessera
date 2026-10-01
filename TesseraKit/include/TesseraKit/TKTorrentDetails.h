#import <TesseraKit/TKDefines.h>

NS_ASSUME_NONNULL_BEGIN

/// Facts about a torrent that do not change while it downloads.
NS_SWIFT_NAME(TorrentDetails)
NS_SWIFT_SENDABLE
TK_EXPORT
@interface TKTorrentDetails : NSObject

@property (nonatomic, readonly, copy) NSString *torrentID;
@property (nonatomic, readonly, copy) NSString *name;
/// 40 hex characters. nil for v2-only torrents.
@property (nonatomic, readonly, copy, nullable) NSString *infoHashV1;
/// 64 hex characters. nil for v1-only torrents.
@property (nonatomic, readonly, copy, nullable) NSString *infoHashV2;
@property (nonatomic, readonly, copy) NSString *magnetLink;
@property (nonatomic, readonly) BOOL hasMetadata;
/// Private torrents only use their trackers: no DHT, peer exchange or local discovery.
@property (nonatomic, readonly, getter=isPrivate) BOOL privateTorrent;
@property (nonatomic, readonly, copy) NSString *comment;
@property (nonatomic, readonly, copy) NSString *creator;
@property (nonatomic, readonly, copy, nullable) NSDate *creationDate;
@property (nonatomic, readonly) int64_t totalSize;
@property (nonatomic, readonly) NSInteger pieceLength;
@property (nonatomic, readonly) NSInteger numPieces;
@property (nonatomic, readonly) NSInteger fileCount;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
