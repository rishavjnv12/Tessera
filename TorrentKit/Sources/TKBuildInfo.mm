#import <TorrentKit/TKBuildInfo.h>

#include <boost/version.hpp>
#include <libtorrent/hasher.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/version.hpp>
#include <openssl/crypto.h>

#include <cstring>
#include <exception>
#include <string>

namespace lt = libtorrent;

@implementation TKBuildInfo

+ (NSString *)libtorrentVersion {
    return @(lt::version());
}

+ (NSString *)opensslVersion {
    return @(OpenSSL_version(OPENSSL_VERSION_STRING));
}

+ (NSString *)boostVersion {
    std::string v = BOOST_LIB_VERSION; // e.g. "1_92"
    for (auto &c : v) if (c == '_') c = '.';
    return @(v.c_str());
}

+ (nullable NSString *)runSelfTest {
    try {
        // SHA-1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
        static const unsigned char expected[20] = {
            0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81, 0x6a, 0xba, 0x3e,
            0x25, 0x71, 0x78, 0x50, 0xc2, 0x6c, 0x9c, 0xd0, 0xd8, 0x9d};
        lt::sha1_hash const digest = lt::hasher("abc", 3).final();
        if (std::memcmp(digest.data(), expected, sizeof(expected)) != 0) {
            return @"SHA-1 digest mismatch";
        }

        lt::settings_pack pack;
        pack.set_str(lt::settings_pack::listen_interfaces, "");
        pack.set_bool(lt::settings_pack::enable_dht, false);
        pack.set_bool(lt::settings_pack::enable_lsd, false);
        pack.set_bool(lt::settings_pack::enable_upnp, false);
        pack.set_bool(lt::settings_pack::enable_natpmp, false);
        {
            lt::session session{lt::session_params{pack}};
            if (!session.is_valid()) return @"Session handle is invalid";
        } // destructor waits for the session to shut down
        return nil;
    } catch (std::exception const &e) {
        return [NSString stringWithFormat:@"C++ exception: %s", e.what()];
    }
}

@end
