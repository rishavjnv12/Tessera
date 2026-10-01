//  TesseraKit — Swift-friendly facade over libtorrent.
//  Public headers are plain Objective-C only. All C++ stays inside .mm files.

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT double TesseraKitVersionNumber;
FOUNDATION_EXPORT const unsigned char TesseraKitVersionString[];

#import <TesseraKit/TKDefines.h>
#import <TesseraKit/TKBuildInfo.h>
#import <TesseraKit/TKSessionSettings.h>
#import <TesseraKit/TKAddTorrentOptions.h>
#import <TesseraKit/TKTorrentStatus.h>
#import <TesseraKit/TKFileEntry.h>
#import <TesseraKit/TKPieceMap.h>
#import <TesseraKit/TKPeer.h>
#import <TesseraKit/TKTracker.h>
#import <TesseraKit/TKTorrentDetails.h>
#import <TesseraKit/TKTorrentPreview.h>
#import <TesseraKit/TKSessionSnapshot.h>
#import <TesseraKit/TKTorrentEvent.h>
#import <TesseraKit/TKSession.h>
#import <TesseraKit/TKJSONCoding.h>
