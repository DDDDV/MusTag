# Third-party sources

The following sources were explicitly approved by the user. TagLib, Chromaprint and utf8cpp were vendored from official tagged archives; SMBClient was copied byte-for-byte from the existing NetMusic checkout. No third-party source files were modified in this task. Build configuration lives separately in `Native/Config` and `project.yml`.

`vendor-lock.json` records official archive URLs and archive SHA-256 values where applicable, local-copy provenance for SMBClient, and per-file hashes for every bundled library. `python3 scripts/verify-vendor.py` verifies the checkout without network access.

| Component | Version | Upstream archive | License |
| --- | --- | --- | --- |
| TagLib | 2.3.2 | https://codeload.github.com/taglib/taglib/tar.gz/refs/tags/v2.3.2 | LGPL / MPL 1.1 alternative licenses |
| Chromaprint | 1.6.2 | https://codeload.github.com/acoustid/chromaprint/tar.gz/refs/tags/v1.6.2 | LGPL 2.1 as a whole; component MIT notices retained |
| SMBClient | Pinned local snapshot (per-file hashes) | Existing NetPlayer/ThirdParty/SMBClient; no network download | MIT |
| utf8cpp | 4.0.6 | https://codeload.github.com/nemtrif/utfcpp/tar.gz/refs/tags/v4.0.6 | Boost Software License 1.0 |

TagLib links Apple's system zlib. Chromaprint uses Apple's Accelerate/vDSP FFT and the resampler already included by upstream. No additional FFT, FFmpeg distribution, CMake installation, or package-manager dependencies are needed for this Xcode project.

Full upstream source and license notices are retained in `Vendor`. Offline notices are included in the App's Settings → Open-source licenses. The LGPL text bundled for TagLib is also the version referenced by Chromaprint. Binary distribution requires satisfying the applicable source/relinking obligations; retaining sources alone should not be treated as a completed App Store distribution review.

The audio fixtures in `Tests/Fixtures` are unchanged copies from TagLib's upstream test corpus. Test operations modify temporary copies only. `sample.mp3` comes from `bladeenc.mp3`; `truncated.mp3` comes from the deliberately incomplete `lame_cbr.mp3` corpus sample.

AcoustID and MusicBrainz are external services, not bundled libraries. The present integration is for personal testing; commercial API use has separate terms.

The WebDAV, FTP, SMB adapter, music-server and WiFi receiver implementations reference the user-provided NetMusic project. Only SMBClient is a newly linked third-party component; its original Package.swift, Sources, Tests and notices are retained unchanged. No libcurl, FFmpeg, GRDB or cloud-provider dependency was added.
