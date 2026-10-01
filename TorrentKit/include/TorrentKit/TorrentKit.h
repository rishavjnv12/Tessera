//  TorrentKit — Swift-friendly facade over libtorrent.
//  Public headers are plain Objective-C only. All C++ stays inside .mm files.

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT double TorrentKitVersionNumber;
FOUNDATION_EXPORT const unsigned char TorrentKitVersionString[];

#import <TorrentKit/TKDefines.h>
#import <TorrentKit/TKBuildInfo.h>
#import <TorrentKit/TKSessionSettings.h>
#import <TorrentKit/TKAddTorrentOptions.h>
#import <TorrentKit/TKTorrentStatus.h>
#import <TorrentKit/TKFileEntry.h>
#import <TorrentKit/TKPieceMap.h>
#import <TorrentKit/TKPeer.h>
#import <TorrentKit/TKTracker.h>
#import <TorrentKit/TKTorrentDetails.h>
#import <TorrentKit/TKTorrentPreview.h>
#import <TorrentKit/TKSessionSnapshot.h>
#import <TorrentKit/TKTorrentEvent.h>
#import <TorrentKit/TKSession.h>
#import <TorrentKit/TKJSONCoding.h>
