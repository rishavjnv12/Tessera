#import "TKInternal.h"

#import <objc/runtime.h>

// Generic JSON coding for TorrentKit's immutable value objects, driven by their declared
// properties. Reading goes through the getters; writing sets the backing ivars through
// key-value coding, which reaches readonly properties.

namespace {

enum class Kind { number, string, date, data, other };

struct Property {
    NSString *name;
    Kind kind;
};

std::vector<Property> TKProperties(Class cls) {
    std::vector<Property> result;
    unsigned count = 0;
    objc_property_t *list = class_copyPropertyList(cls, &count);
    for (unsigned i = 0; i < count; ++i) {
        NSString *name = @(property_getName(list[i]));
        if ([name isEqualToString:@"jsonObject"] || [name isEqualToString:@"hash"] || [name isEqualToString:@"superclass"]
            || [name isEqualToString:@"description"] || [name isEqualToString:@"debugDescription"]) continue;
        char *type = property_copyAttributeValue(list[i], "T");
        NSString *t = type ? @(type) : @"";
        free(type);
        Kind kind = Kind::other;
        if ([t isEqualToString:@"@\"NSString\""]) kind = Kind::string;
        else if ([t isEqualToString:@"@\"NSDate\""]) kind = Kind::date;
        else if ([t isEqualToString:@"@\"NSData\""]) kind = Kind::data;
        else if (t.length == 1) kind = Kind::number; // scalars: c, i, q, Q, d, B, ...
        if (kind != Kind::other) result.push_back({name, kind});
    }
    free(list);
    return result;
}

NSDictionary<NSString *, id> *TKEncode(NSObject *object) {
    NSMutableDictionary *json = [NSMutableDictionary dictionary];
    for (Property const &p : TKProperties(object.class)) {
        id value = [object valueForKey:p.name];
        if (!value) continue;
        switch (p.kind) {
            case Kind::date: json[p.name] = @([(NSDate *)value timeIntervalSince1970]); break;
            case Kind::data: json[p.name] = [(NSData *)value base64EncodedStringWithOptions:0]; break;
            default: json[p.name] = value; break;
        }
    }
    return json;
}

BOOL TKDecode(NSObject *object, NSDictionary<NSString *, id> *json) {
    for (Property const &p : TKProperties(object.class)) {
        id value = json[p.name];
        if (!value || value == NSNull.null) continue;
        switch (p.kind) {
            case Kind::number:
                if (![value isKindOfClass:NSNumber.class]) return NO;
                break;
            case Kind::string:
                if (![value isKindOfClass:NSString.class]) return NO;
                break;
            case Kind::date:
                if (![value isKindOfClass:NSNumber.class]) return NO;
                value = [NSDate dateWithTimeIntervalSince1970:[value doubleValue]];
                break;
            case Kind::data:
                if (![value isKindOfClass:NSString.class]) return NO;
                value = [[NSData alloc] initWithBase64EncodedString:value options:0];
                if (!value) return NO;
                break;
            case Kind::other:
                continue;
        }
        @try {
            [object setValue:value forKey:p.name];
        } @catch (NSException *) {
            return NO;
        }
    }
    return YES;
}

} // namespace

#define TK_JSON_CODING(Class, Required)                                              \
    @implementation Class (TKJSONCoding)                                              \
    - (NSDictionary<NSString *, id> *)jsonObject { return TKEncode(self); }         \
    - (nullable instancetype)initWithJSONObject:(NSDictionary<NSString *, id> *)json { \
        if (![json isKindOfClass:NSDictionary.class] || !json[Required]) return nil;  \
        self = [super init];                                                          \
        return (self && TKDecode(self, json)) ? self : nil;                            \
    }                                                                                 \
    @end

TK_JSON_CODING(TKTorrentStatus, @"torrentID")
TK_JSON_CODING(TKFileEntry, @"path")
TK_JSON_CODING(TKPeer, @"address")
TK_JSON_CODING(TKTracker, @"url")
TK_JSON_CODING(TKTorrentDetails, @"torrentID")
TK_JSON_CODING(TKPieceMap, @"torrentID")
