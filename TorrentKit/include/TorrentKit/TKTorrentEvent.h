#import <TorrentKit/TKDefines.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TKTorrentEventKind) {
    TKTorrentEventKindAdded = 0,
    TKTorrentEventKindMetadataReceived,
    /// All wanted files finished downloading. Not sent again for torrents restored as complete.
    TKTorrentEventKindFinished,
    TKTorrentEventKindRemoved,
    /// Files were deleted after removing a torrent with `deleteFiles`.
    TKTorrentEventKindFilesDeleted,
    /// A torrent hit an error, such as a disk or tracker failure.
    TKTorrentEventKindTorrentError,
    /// A session-wide problem, such as failing to listen on the port.
    TKTorrentEventKindSessionError,
} NS_SWIFT_NAME(TorrentEvent.Kind);

/// Something that happened, for notifications and logs.
NS_SWIFT_NAME(TorrentEvent)
NS_SWIFT_SENDABLE
TK_EXPORT
@interface TKTorrentEvent : NSObject

@property (nonatomic, readonly) TKTorrentEventKind kind;
/// nil for session-wide events.
@property (nonatomic, readonly, copy, nullable) NSString *torrentID;
@property (nonatomic, readonly, copy, nullable) NSString *torrentName;
@property (nonatomic, readonly, copy, nullable) NSString *message;
@property (nonatomic, readonly, copy) NSDate *date;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
