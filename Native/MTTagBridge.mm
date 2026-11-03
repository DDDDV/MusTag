#import "MTTagBridge.h"
#import <ImageIO/ImageIO.h>
#include "fileref.h"
#include "tpropertymap.h"
#include "mpegfile.h"
#include "mpegheader.h"
#include "id3v2tag.h"
#include "id3v2header.h"
#include "attachedpictureframe.h"
#include "flacfile.h"
#include "flacpicture.h"
#include "mp4file.h"
#include "mp4tag.h"
#include "mp4coverart.h"
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

// Decode only a small thumbnail after checking dimensions, so oversized or malformed
// embedded images cannot force an unbounded bitmap allocation during import.
static NSDictionary *MTImageInfo(NSData *data) {
    if(data.length == 0 || data.length > 8 * 1024 * 1024) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    if(!source) return nil;
    CFStringRef type = CGImageSourceGetType(source);
    NSString *mime = type && CFEqual(type, CFSTR("public.jpeg")) ? @"image/jpeg" :
        (type && CFEqual(type, CFSTR("public.png")) ? @"image/png" : nil);
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
    NSInteger width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] integerValue];
    NSInteger height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] integerValue];
    if(!mime || width <= 0 || height <= 0 || width > 16384 || height > 16384 ||
       width * height > 40000000 || CGImageSourceGetStatus(source) != kCGImageStatusComplete) {
        CFRelease(source);
        return nil;
    }
    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @16,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    if(!image || CGImageSourceGetStatusAtIndex(source, 0) != kCGImageStatusComplete) {
        if(image) CGImageRelease(image);
        CFRelease(source);
        return nil;
    }
    NSNumber *depth = @(CGImageGetBitsPerPixel(image));
    CGImageRelease(image);
    CFRelease(source);
    return @{@"mimeType": mime, @"width": @(width), @"height": @(height), @"depth": depth};
}

static NSDictionary *MTArtwork(const TagLib::ByteVector &bytes) {
    if(bytes.isEmpty() || bytes.size() > 8 * 1024 * 1024) return nil;
    NSData *data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
    NSDictionary *info = MTImageInfo(data);
    return info ? @{@"data": data, @"mimeType": info[@"mimeType"]} : nil;
}

static NSDictionary *MTReadArtwork(TagLib::File *file) {
    NSDictionary *fallback = nil;
    if(auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file)) {
        if(auto *tag = mpeg->ID3v2Tag()) {
            for(auto *frame : tag->frameList("APIC")) {
                auto *picture = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frame);
                if(!picture) continue;
                NSDictionary *artwork = MTArtwork(picture->picture());
                if(!artwork) continue;
                if(picture->type() == TagLib::ID3v2::AttachedPictureFrame::FrontCover) return artwork;
                if(!fallback) fallback = artwork;
            }
        }
    } else if(auto *flac = dynamic_cast<TagLib::FLAC::File *>(file)) {
        for(auto *picture : flac->pictureList()) {
            NSDictionary *artwork = MTArtwork(picture->data());
            if(!artwork) continue;
            if(picture->type() == TagLib::FLAC::Picture::FrontCover) return artwork;
            if(!fallback) fallback = artwork;
        }
    } else if(auto *mp4 = dynamic_cast<TagLib::MP4::File *>(file)) {
        for(const auto &picture : mp4->tag()->item("covr").toCoverArtList()) {
            if(NSDictionary *artwork = MTArtwork(picture.data())) return artwork;
        }
    }
    return fallback;
}

static bool MTCanEdit(TagLib::FileRef &file, NSError **error) {
    if(file.isNull() || !file.file()->isValid() || file.file()->readOnly()) {
        MTError(error, @"This audio file cannot be modified."); return false;
    }
    if(auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file.file())) {
        if(auto *tag = mpeg->ID3v2Tag()) {
            for(const auto *frame : tag->frameList()) {
                if(frame->frameID().size() != 4 || frame->header()->tagAlterPreservation()) {
                    MTError(error, @"This MP3 contains a legacy or discard-on-edit tag that cannot be preserved safely. The original was not changed.");
                    return false;
                }
            }
        }
    }
    return true;
}

static bool MTSave(TagLib::FileRef &file) {
    if(auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file.file())) {
        auto *tag = mpeg->ID3v2Tag();
        auto version = tag && tag->header()->majorVersion() == 3 ? TagLib::ID3v2::v3 : TagLib::ID3v2::v4;
        return mpeg->save(TagLib::MPEG::File::AllTags, TagLib::File::StripNone, version, TagLib::File::DoNotDuplicate);
    }
    return file.save();
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
            tags[key] = MTString(properties.value(property));
        }
        double duration = file.audioProperties() ? file.audioProperties()->lengthInMilliseconds() / 1000.0 : 0;
        NSMutableDictionary *result = [@{@"tags": tags, @"duration": @(duration)} mutableCopy];
        if(NSDictionary *artwork = MTReadArtwork(file.file())) result[@"artwork"] = artwork;
        return result;
    } catch(const std::exception &e) { MTError(error, [NSString stringWithUTF8String:e.what()]); }
      catch(...) { MTError(error, @"The audio metadata is malformed."); }
    return nil;
}

+ (BOOL)writeTags:(NSDictionary<NSString *,NSString *> *)tags toURL:(NSURL *)url error:(NSError **)error {
    try {
        TagLib::FileRef file(url.fileSystemRepresentation, true);
        if(!MTCanEdit(file, error)) return NO;
        auto properties = file.file()->properties();
        // Start from the full map; changing one field must not erase other tags.
        for(NSString *key in MTKeys()) {
            NSString *value = tags[key];
            if(!value) continue;
            auto property = TagLib::String([MTKeys()[key] UTF8String], TagLib::String::UTF8);
            // A non-const subscript inserts a missing key with an empty list. MP4
            // then serializes empty TRACKNUMBER/DISCNUMBER lists as numeric zero.
            // Reading without insertion preserves absent fields during other edits.
            if([MTString(properties.value(property)) isEqualToString:value]) continue;
            if(value.length == 0) properties.erase(property);
            else properties.replace(property, TagLib::StringList(TagLib::String(value.UTF8String, TagLib::String::UTF8)));
        }
        auto unsupported = file.file()->setProperties(properties);
        for(NSString *key in MTKeys()) {
            if(unsupported.contains(TagLib::String([MTKeys()[key] UTF8String], TagLib::String::UTF8))) {
                MTError(error, @"A requested field cannot be stored in this format."); return NO;
            }
        }
        bool saved = MTSave(file);
        if(!saved) MTError(error, @"Could not save the audio metadata.");
        return saved;
    } catch(const std::exception &e) { MTError(error, [NSString stringWithUTF8String:e.what()]); }
      catch(...) { MTError(error, @"The audio metadata could not be written."); }
    return NO;
}

+ (BOOL)writeArtwork:(NSData *)data mimeType:(NSString *)mimeType toURL:(NSURL *)url error:(NSError **)error {
    NSDictionary *info = MTImageInfo(data);
    if(!info || ![info[@"mimeType"] isEqualToString:mimeType]) {
        MTError(error, @"The cover must be a valid JPEG or PNG image no larger than 8 MB."); return NO;
    }
    try {
        TagLib::FileRef file(url.fileSystemRepresentation, true);
        if(!MTCanEdit(file, error)) return NO;
        TagLib::ByteVector bytes(static_cast<const char *>(data.bytes), static_cast<unsigned int>(data.length));
        if(auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file.file())) {
            auto *tag = mpeg->ID3v2Tag(true);
            const auto frames = tag->frameList("APIC");
            for(auto *frame : frames) {
                auto *picture = dynamic_cast<TagLib::ID3v2::AttachedPictureFrame *>(frame);
                if(picture && picture->type() == TagLib::ID3v2::AttachedPictureFrame::FrontCover)
                    tag->removeFrame(frame);
            }
            auto *picture = new TagLib::ID3v2::AttachedPictureFrame();
            picture->setType(TagLib::ID3v2::AttachedPictureFrame::FrontCover);
            picture->setMimeType(TagLib::String(mimeType.UTF8String, TagLib::String::UTF8));
            picture->setPicture(bytes);
            tag->addFrame(picture);
        } else if(auto *flac = dynamic_cast<TagLib::FLAC::File *>(file.file())) {
            const auto pictures = flac->pictureList();
            for(auto *picture : pictures) {
                if(picture->type() == TagLib::FLAC::Picture::FrontCover) flac->removePicture(picture);
            }
            auto *picture = new TagLib::FLAC::Picture();
            picture->setType(TagLib::FLAC::Picture::FrontCover);
            picture->setMimeType(TagLib::String(mimeType.UTF8String, TagLib::String::UTF8));
            picture->setWidth([info[@"width"] intValue]);
            picture->setHeight([info[@"height"] intValue]);
            picture->setColorDepth([info[@"depth"] intValue]);
            picture->setNumColors(0);
            picture->setData(bytes);
            flac->addPicture(picture);
        } else if(auto *mp4 = dynamic_cast<TagLib::MP4::File *>(file.file())) {
            const auto existing = mp4->tag()->item("covr").toCoverArtList();
            TagLib::MP4::CoverArtList pictures;
            pictures.append(TagLib::MP4::CoverArt([mimeType isEqualToString:@"image/png"] ?
                TagLib::MP4::CoverArt::PNG : TagLib::MP4::CoverArt::JPEG, bytes));
            // MP4 has no front/back picture type. The first entry is the displayed cover.
            for(unsigned int index = 1; index < existing.size(); ++index) pictures.append(existing[index]);
            mp4->tag()->setItem("covr", TagLib::MP4::Item(pictures));
        } else {
            MTError(error, @"Cover writing is supported for MP3, FLAC and M4A files."); return NO;
        }
        bool saved = MTSave(file);
        if(!saved) MTError(error, @"Could not save the cover image.");
        return saved;
    } catch(const std::exception &e) { MTError(error, [NSString stringWithUTF8String:e.what()]); }
      catch(...) { MTError(error, @"The cover image could not be written."); }
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
