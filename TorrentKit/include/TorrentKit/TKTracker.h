#import <TorrentKit/TKDefines.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TKTrackerStatus) {
    TKTrackerStatusNotContacted = 0,
    TKTrackerStatusUpdating,
    TKTrackerStatusWorking,
    TKTrackerStatusError,
} NS_SWIFT_NAME(Tracker.Status);

/// A tracker of a torrent and how its announces are going.
NS_SWIFT_NAME(Tracker)
NS_SWIFT_SENDABLE
TK_EXPORT
@interface TKTracker : NSObject

@property (nonatomic, readonly, copy) NSString *url;
/// Trackers in lower tiers are tried first.
@property (nonatomic, readonly) NSInteger tier;
@property (nonatomic, readonly) TKTrackerStatus status;
/// The tracker's message or the last error. May be empty.
@property (nonatomic, readonly, copy) NSString *message;
/// From the tracker's last scrape. -1 when unknown.
@property (nonatomic, readonly) NSInteger seeds;
@property (nonatomic, readonly) NSInteger peers;
@property (nonatomic, readonly) NSInteger downloaded;
@property (nonatomic, readonly, copy, nullable) NSDate *nextAnnounce;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
