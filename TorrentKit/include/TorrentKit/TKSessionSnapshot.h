#import <TorrentKit/TKDefines.h>

@class TKTorrentStatus;

NS_ASSUME_NONNULL_BEGIN

/// Everything the UI needs for one refresh, delivered about once per second.
NS_SWIFT_NAME(SessionSnapshot)
NS_SWIFT_SENDABLE
TK_EXPORT
@interface TKSessionSnapshot : NSObject

/// All torrents, in the order they were added.
@property (nonatomic, readonly, copy) NSArray<TKTorrentStatus *> *torrents;
/// Payload bytes per second summed over all torrents.
@property (nonatomic, readonly) int64_t downloadRate;
@property (nonatomic, readonly) int64_t uploadRate;
/// Nodes in the DHT routing table. 0 while DHT is off or bootstrapping.
@property (nonatomic, readonly) NSInteger dhtNodes;
/// Port the session listens on. 0 when not listening.
@property (nonatomic, readonly) NSInteger listenPort;
@property (nonatomic, readonly, copy) NSDate *date;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
