#import <Foundation/Foundation.h>

// TorrentKit hides symbols by default (GCC_SYMBOLS_PRIVATE_EXTERN) so libtorrent and
// OpenSSL internals stay private. Every public class must be marked with TK_EXPORT.
#define TK_EXPORT __attribute__((visibility("default")))
