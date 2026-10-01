#import <TesseraKit/TKDefines.h>

NS_ASSUME_NONNULL_BEGIN

/// Engine-wide settings. Copy, change and pass to `-[TKSession applySettings:]`.
NS_SWIFT_NAME(SessionSettings)
TK_EXPORT
@interface TKSessionSettings : NSObject <NSCopying>

/// Incoming connection port. 0 picks a random free port. -1 disables listening.
@property (nonatomic) NSInteger listenPort;
/// Advanced override for libtorrent's `listen_interfaces`, e.g. "127.0.0.1:0".
/// When set, `listenPort` is ignored.
@property (nonatomic, copy, nullable) NSString *listenInterfaces;

/// Bytes per second. 0 means unlimited.
@property (nonatomic) int64_t downloadRateLimit;
/// Bytes per second. 0 means unlimited.
@property (nonatomic) int64_t uploadRateLimit;

/// Maximum peer connections across all torrents. 0 keeps libtorrent's default.
@property (nonatomic) NSInteger maxConnections;
/// Torrents allowed to download at once. -1 means unlimited.
@property (nonatomic) NSInteger activeDownloads;
/// Torrents allowed to seed at once. -1 means unlimited.
@property (nonatomic) NSInteger activeSeeds;

/// Distributed hash table, used to find peers without a tracker.
@property (nonatomic) BOOL enableDHT;
/// Local service discovery, finds peers on the local network.
@property (nonatomic) BOOL enableLSD;
/// Peer exchange, learns peers from other peers.
@property (nonatomic) BOOL enablePEX;
/// Automatic port forwarding on the router.
@property (nonatomic) BOOL enableUPnP;
@property (nonatomic) BOOL enableNATPMP;

/// Settings suitable for a normal client: listening on a random port, all discovery on.
- (instancetype)init NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
