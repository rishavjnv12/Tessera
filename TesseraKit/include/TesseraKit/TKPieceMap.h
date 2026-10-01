#import <TesseraKit/TKDefines.h>

NS_ASSUME_NONNULL_BEGIN

/// Values in `TKPieceMap.fill`.
typedef NS_ENUM(uint8_t, TKPieceFill) {
    TKPieceFillMissing = 0,
    /// 1...254 mean the piece is being downloaded. The value scales with the share of blocks received.
    TKPieceFillDownloadingMin = 1,
    TKPieceFillDownloadingMax = 254,
    TKPieceFillHave = 255,
} NS_SWIFT_NAME(PieceFill);

/// Per-piece state of one torrent at one moment. One entry per piece in each array.
NS_SWIFT_NAME(PieceSnapshot)
NS_SWIFT_SENDABLE
TK_EXPORT
@interface TKPieceMap : NSObject

@property (nonatomic, readonly, copy) NSString *torrentID;
/// 0 until metadata is known.
@property (nonatomic, readonly) NSInteger pieceCount;
@property (nonatomic, readonly) NSInteger pieceLength;
@property (nonatomic, readonly) int64_t totalSize;
/// UInt8 per piece. See `TKPieceFill`.
@property (nonatomic, readonly, copy) NSData *fill;
/// UInt8 per piece: 0 skip, 1 lowest, 4 normal, 7 highest.
@property (nonatomic, readonly, copy) NSData *priorities;
/// UInt16 per piece: connected peers that have the piece.
@property (nonatomic, readonly, copy) NSData *availability;
/// libtorrent does not track availability while seeding; `availability` is then all zero.
@property (nonatomic, readonly) BOOL tracksAvailability;

/// Builds a piece map from its parts, e.g. one received from another device.
- (instancetype)initWithID:(NSString *)torrentID
               pieceLength:(NSInteger)pieceLength
                 totalSize:(int64_t)totalSize
                      fill:(NSData *)fill
                priorities:(NSData *)priorities
              availability:(NSData *)availability
        tracksAvailability:(BOOL)tracksAvailability NS_SWIFT_NAME(init(torrentID:pieceLength:totalSize:fill:priorities:availability:tracksAvailability:));

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
