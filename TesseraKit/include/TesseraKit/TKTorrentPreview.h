#import <TesseraKit/TKDefines.h>

NS_ASSUME_NONNULL_BEGIN

/// One file listed in a torrent that has not been added yet.
NS_SWIFT_NAME(TorrentPreview.File)
NS_SWIFT_SENDABLE
TK_EXPORT
@interface TKTorrentPreviewFile : NSObject
/// Same index as `TKFileEntry.index` once added; use it for `TKAddTorrentOptions.filePriorities`.
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) int64_t size;
- (instancetype)init NS_UNAVAILABLE;
@end

/// What a .torrent file or magnet link contains, read without adding it. Used by the add sheet.
NS_SWIFT_NAME(TorrentPreview)
NS_SWIFT_SENDABLE
TK_EXPORT
@interface TKTorrentPreview : NSObject

/// The ID the torrent will have once added.
@property (nonatomic, readonly, copy) NSString *torrentID;
@property (nonatomic, readonly, copy) NSString *name;
/// 0 for magnet links: the size is known only once metadata arrives.
@property (nonatomic, readonly) int64_t totalSize;
/// Empty for magnet links. Pad files are left out.
@property (nonatomic, readonly, copy) NSArray<TKTorrentPreviewFile *> *files;
@property (nonatomic, readonly, getter=isPrivate) BOOL privateTorrent;
@property (nonatomic, readonly, copy) NSString *comment;
@property (nonatomic, readonly) BOOL isMagnet;

+ (nullable instancetype)previewWithData:(NSData *)data error:(NSError **)error NS_SWIFT_NAME(init(data:));
+ (nullable instancetype)previewWithMagnetLink:(NSString *)link error:(NSError **)error NS_SWIFT_NAME(init(magnet:));

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
