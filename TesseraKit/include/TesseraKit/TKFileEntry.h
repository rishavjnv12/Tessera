#import <TesseraKit/TKDefines.h>

NS_ASSUME_NONNULL_BEGIN

/// One file inside a torrent, with the pieces it spans.
NS_SWIFT_NAME(TorrentFile)
NS_SWIFT_SENDABLE
TK_EXPORT
@interface TKFileEntry : NSObject

/// Index in the torrent's file list. Stable, used for file priorities.
@property (nonatomic, readonly) NSInteger index;
/// Path inside the torrent, including the torrent's root folder for multi-file torrents.
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) int64_t size;
/// Byte offset of the file within the torrent's concatenated data.
@property (nonatomic, readonly) int64_t offset;
/// First and last piece (inclusive) that hold bytes of this file. -1 for empty files.
@property (nonatomic, readonly) NSInteger firstPiece;
@property (nonatomic, readonly) NSInteger lastPiece;
@property (nonatomic, readonly) int64_t downloadedBytes;
/// 0...1
@property (nonatomic, readonly) double progress;
/// libtorrent priority: 0 skip, 1 lowest, 4 normal, 7 highest.
@property (nonatomic, readonly) NSInteger priority;
/// Bytes downloaded without gaps from the start of the file: how far it can be read or played.
@property (nonatomic, readonly) int64_t contiguousBytes;
/// The last megabyte (or less) of the file is downloaded. Many video formats keep their index there.
@property (nonatomic, readonly) BOOL hasEnd;
/// This file is being downloaded from its start.
@property (nonatomic, readonly) BOOL downloadsFromStart;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
