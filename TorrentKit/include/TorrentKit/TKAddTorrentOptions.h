#import <TorrentKit/TKDefines.h>

NS_ASSUME_NONNULL_BEGIN

/// Options for adding a torrent.
NS_SWIFT_NAME(AddTorrentOptions)
TK_EXPORT
@interface TKAddTorrentOptions : NSObject <NSCopying>

/// Folder to download into. nil uses the session's default save path.
@property (nonatomic, copy, nullable) NSURL *savePath;
/// Add the torrent paused instead of starting it immediately.
@property (nonatomic) BOOL startPaused;
/// Priority for each file by index (0 skips a file). nil downloads everything. Ignored for
/// magnet links, whose files are unknown when added.
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *filePriorities;

@end

NS_ASSUME_NONNULL_END
