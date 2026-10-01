#import <TesseraKit/TKTorrentStatus.h>
#import <TesseraKit/TKFileEntry.h>
#import <TesseraKit/TKPeer.h>
#import <TesseraKit/TKTracker.h>
#import <TesseraKit/TKTorrentDetails.h>
#import <TesseraKit/TKPieceMap.h>

NS_ASSUME_NONNULL_BEGIN

/// Converts TesseraKit's value objects to and from JSON-compatible dictionaries, for sending
/// them between devices (remote control). Keys are the property names. Dates become seconds
/// since 1970 and data becomes base64 strings; nil properties are left out.
NS_SWIFT_NAME(JSONRepresentable)
@protocol TKJSONRepresentable <NSObject>
@property (nonatomic, readonly) NSDictionary<NSString *, id> *jsonObject;
/// nil when `json` is not a valid encoding of this class.
- (nullable instancetype)initWithJSONObject:(NSDictionary<NSString *, id> *)json;
@end

@interface TKTorrentStatus (TKJSONCoding) <TKJSONRepresentable> @end
@interface TKFileEntry (TKJSONCoding) <TKJSONRepresentable> @end
@interface TKPeer (TKJSONCoding) <TKJSONRepresentable> @end
@interface TKTracker (TKJSONCoding) <TKJSONRepresentable> @end
@interface TKTorrentDetails (TKJSONCoding) <TKJSONRepresentable> @end
@interface TKPieceMap (TKJSONCoding) <TKJSONRepresentable> @end

NS_ASSUME_NONNULL_END
