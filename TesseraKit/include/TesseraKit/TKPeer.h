#import <TesseraKit/TKDefines.h>

NS_ASSUME_NONNULL_BEGIN

/// Where a peer was learned from.
typedef NS_OPTIONS(NSUInteger, TKPeerSource) {
    TKPeerSourceTracker = 1 << 0,
    TKPeerSourceDHT = 1 << 1,
    TKPeerSourcePEX = 1 << 2,
    TKPeerSourceLSD = 1 << 3,
    TKPeerSourceResumeData = 1 << 4,
    TKPeerSourceIncoming = 1 << 5,
} NS_SWIFT_NAME(PeerSource);

/// One connected peer of a torrent.
NS_SWIFT_NAME(Peer)
NS_SWIFT_SENDABLE
TK_EXPORT
@interface TKPeer : NSObject

/// "ip:port", with brackets around IPv6 addresses.
@property (nonatomic, readonly, copy) NSString *address;
/// Client name and version the peer reports, e.g. "qBittorrent 5.1.0". May be empty.
@property (nonatomic, readonly, copy) NSString *client;
@property (nonatomic, readonly) int64_t downloadRate;
@property (nonatomic, readonly) int64_t uploadRate;
@property (nonatomic, readonly) int64_t totalDownloaded;
@property (nonatomic, readonly) int64_t totalUploaded;
/// Share of the torrent the peer has, 0...1.
@property (nonatomic, readonly) double progress;
@property (nonatomic, readonly, getter=isSeed) BOOL seed;
/// The peer connected to us.
@property (nonatomic, readonly, getter=isIncoming) BOOL incoming;
@property (nonatomic, readonly, getter=isEncrypted) BOOL encrypted;
/// Connected over uTP (UDP) instead of TCP.
@property (nonatomic, readonly, getter=isUTP) BOOL utp;
/// An HTTP web seed rather than a BitTorrent peer.
@property (nonatomic, readonly, getter=isWebSeed) BOOL webSeed;
@property (nonatomic, readonly) TKPeerSource source;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
