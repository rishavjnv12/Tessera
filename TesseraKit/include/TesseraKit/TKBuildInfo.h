#import <TesseraKit/TKDefines.h>

NS_ASSUME_NONNULL_BEGIN

/// Versions of the native libraries linked into TesseraKit, plus a smoke test.
NS_SWIFT_NAME(BuildInfo)
TK_EXPORT
@interface TKBuildInfo : NSObject

@property (class, nonatomic, readonly) NSString *libtorrentVersion;
@property (class, nonatomic, readonly) NSString *opensslVersion;
@property (class, nonatomic, readonly) NSString *boostVersion;

/// Hashes a known string with libtorrent's SHA-1 and starts and stops a session
/// with networking disabled. Returns nil on success, or a description of the failure.
/// Blocks for a moment, so call it off the main thread.
+ (nullable NSString *)runSelfTest;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
