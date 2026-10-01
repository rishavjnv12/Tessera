#import <Foundation/Foundation.h>

// TesseraKit hides symbols by default (GCC_SYMBOLS_PRIVATE_EXTERN) so libtorrent and
// OpenSSL internals stay private. Every public class must be marked with TK_EXPORT.
#define TK_EXPORT __attribute__((visibility("default")))

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT TK_EXPORT NSErrorDomain const TKErrorDomain NS_SWIFT_NAME(TesseraKitErrorDomain);

typedef NS_ERROR_ENUM(TKErrorDomain, TKErrorCode) {
    /// The .torrent file or data could not be parsed.
    TKErrorInvalidTorrent = 1,
    /// The magnet link could not be parsed.
    TKErrorInvalidMagnet = 2,
    /// A torrent with the same info-hash is already in the session.
    TKErrorDuplicateTorrent = 3,
    /// No torrent with the given ID is in the session.
    TKErrorTorrentNotFound = 4,
    /// Reading or writing a file failed.
    TKErrorFileSystem = 5,
    /// libtorrent reported an error. The description carries its message.
    TKErrorEngine = 6,
    /// The session was shut down and cannot be used any more.
    TKErrorSessionClosed = 7,
    /// An argument was out of range or malformed.
    TKErrorInvalidArgument = 8,
    /// The action needs the torrent's metadata, which has not arrived yet.
    TKErrorNoMetadata = 9,
    /// Priorities cannot change once every piece is downloaded.
    TKErrorTorrentComplete = 10,
} NS_SWIFT_NAME(TesseraKitError);

NS_ASSUME_NONNULL_END
