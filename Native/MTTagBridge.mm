#import "MTTagBridge.h"
#include "fileref.h"
#include "tpropertymap.h"
#include "mpegfile.h"
#include "mpegheader.h"
#include "id3v2tag.h"
#include "id3v2header.h"
#include <exception>

static void MTError(NSError **error, NSString *message) {
    if(error) *error = [NSError errorWithDomain:@"MusTag.Native" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSDictionary<NSString *, NSString *> *MTKeys(void) {
    return @{@"title": @"TITLE", @"artist": @"ARTIST", @"album": @"ALBUM",
             @"albumArtist": @"ALBUMARTIST", @"year": @"DATE",
             @"trackNumber": @"TRACKNUMBER", @"discNumber": @"DISCNUMBER", @"genre": @"GENRE"};
}

static NSString *MTString(const TagLib::StringList &values) {
    if(values.isEmpty()) return @"";
    auto bytes = values.toString("; ").to8Bit(true);
    return [[NSString alloc] initWithBytes:bytes.data() length:bytes.size() encoding:NSUTF8StringEncoding] ?: @"";
}

@implementation MTTagBridge
+ (NSDictionary<NSString *,id> *)readURL:(NSURL *)url error:(NSError **)error {
    try {
        TagLib::FileRef file(url.fileSystemRepresentation, true, TagLib::AudioProperties::Accurate);
        if(file.isNull() || !file.file()->isValid()) { MTError(error, @"Unable to read this audio file."); return nil; }
        auto properties = file.file()->properties();
        NSMutableDictionary *tags = [NSMutableDictionary dictionary];
        for(NSString *key in MTKeys()) {
            auto property = TagLib::String([MTKeys()[key] UTF8String], TagLib::String::UTF8);
            tags[key] = MTString(properties[property]);
        }
        double duration = file.audioProperties() ? file.audioProperties()->lengthInMilliseconds() / 1000.0 : 0;
        return @{@"tags": tags, @"duration": @(duration)};
    } catch(const std::exception &e) { MTError(error, [NSString stringWithUTF8String:e.what()]); }
      catch(...) { MTError(error, @"The audio metadata is malformed."); }
    return nil;
}

+ (BOOL)writeTags:(NSDictionary<NSString *,NSString *> *)tags toURL:(NSURL *)url error:(NSError **)error {
    try {
        TagLib::FileRef file(url.fileSystemRepresentation, true);
        if(file.isNull() || !file.file()->isValid() || file.file()->readOnly()) {
            MTError(error, @"This audio file cannot be modified."); return NO;
        }
        if(auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file.file())) {
            if(auto *tag = mpeg->ID3v2Tag()) {
                for(const auto *frame : tag->frameList()) {
                    if(frame->frameID().size() != 4 || frame->header()->tagAlterPreservation()) {
                        MTError(error, @"This MP3 contains a legacy or discard-on-edit tag that cannot be preserved safely. The original was not changed.");
                        return NO;
                    }
                }
            }
        }
        auto properties = file.file()->properties();
        // Start from the full map; changing one field must not erase other tags.
        for(NSString *key in MTKeys()) {
            NSString *value = tags[key];
            if(!value) continue;
            auto property = TagLib::String([MTKeys()[key] UTF8String], TagLib::String::UTF8);
            if([MTString(properties[property]) isEqualToString:value]) continue;
            if(value.length == 0) properties.erase(property);
            else properties.replace(property, TagLib::StringList(TagLib::String(value.UTF8String, TagLib::String::UTF8)));
        }
        auto unsupported = file.file()->setProperties(properties);
        for(NSString *key in MTKeys()) {
            if(unsupported.contains(TagLib::String([MTKeys()[key] UTF8String], TagLib::String::UTF8))) {
                MTError(error, @"A requested field cannot be stored in this format."); return NO;
            }
        }
        bool saved = false;
        if(auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file.file())) {
            auto *tag = mpeg->ID3v2Tag();
            auto version = tag && tag->header()->majorVersion() == 3 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4;
            saved = mpeg->save(TagLib::MPEG::File::AllTags, TagLib::File::StripNone, version, TagLib::File::DoNotDuplicate);
        } else saved = file.save();
        if(!saved) MTError(error, @"Could not save the audio metadata.");
        return saved;
    } catch(const std::exception &e) { MTError(error, [NSString stringWithUTF8String:e.what()]); }
      catch(...) { MTError(error, @"The audio metadata could not be written."); }
    return NO;
}

+ (NSArray<NSNumber *> *)mpegRangeForURL:(NSURL *)url error:(NSError **)error {
    try {
        TagLib::MPEG::File file(url.fileSystemRepresentation, true);
        auto first = file.firstFrameOffset();
        auto last = file.lastFrameOffset();
        if(!file.isValid() || first < 0 || last < first) {
            MTError(error, @"Cannot verify the MPEG audio frames."); return nil;
        }
        // The final frame has no following MPEG header to validate against.
        TagLib::MPEG::Header header(&file, last, false);
        if(!header.isValid() || header.frameLength() <= 0) {
            MTError(error, @"Cannot verify the MPEG audio frames."); return nil;
        }
        return @[@(first), @(last + header.frameLength() - first)];
    } catch(...) { MTError(error, @"Cannot verify the MPEG audio frames."); return nil; }
}
@end
