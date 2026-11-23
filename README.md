# LMS Multichannel & Bitstream Audio Plugin (`v1.2.0`)

`MultichannelAudio` is a Logitech Media Server (LMS 9.0+) plugin that unlocks discrete multichannel LPCM (up to 7.1) and raw IEC 61937 HDMI bitstream passthrough (Dolby Digital Plus Atmos, Dolby TrueHD Atmos, DTS-HD Master Audio / Auro-3D) for Squeezelite players, featuring pure-Perl Matroska (`.mka`) container parsing and seeking.

---

## Features in v1.2.0

- **Pure-Perl Matroska (`.mka`) Parsing:** Complete EBML and Matroska demuxer written in pure Perl without requiring external binary tools (`mkvmerge` or `ffmpeg`).
- **O(1) `Cues` Seeking & Chapter Navigation:** Reads Matroska `Cues` elements for instant time-based seeking, track skipping, and gapless chapter playback.
- **Custom Protocol Handler (`mka://`):** Streams raw elementary bitstream frames directly to Squeezelite over HTTP/slimproto.
- **Separated Transcoding Engine (`custom-convert.conf`):**
  - `# R` (Remote/Stream) rules route `.mka` bitstream tracks directly via `mka://` without container overhead.
  - `# FT` (Local File) rules strip MP4/M4A containers on the fly via `ffmpeg` stream copying while preserving raw E-AC-3 bitstreams.
- **Stereo Downmix Fallback:** Automatically downmixes multichannel audio to stereo when streaming to standard stereo Squeezebox/Squeezelite players or synchronized multi-room groups containing stereo devices.

---

## Plugin Architecture

```
MultichannelAudio/
├── Plugin.pm                          # Main plugin initialization & capability registration
├── install.xml                        # LMS plugin manifest (v1.2.0)
├── custom-convert.conf                # Transcoding & bitstream routing rules
├── custom-types.conf                 # MIME type mappings for MKA, E-AC-3, TrueHD, DTS-HD
├── Format/
│   ├── Matroska.pm                    # Pure-Perl Matroska EBML metadata parser
│   └── Wrapper.pm                     # Multichannel wrapper format parser
└── ProtocolHandler/
    └── ProtocolHandler_Matroska.pm    # Pure-Perl mka:// stream handler & seek engine
```

---

## Installation

### Manual Installation
1. Download `MultichannelAudio-1.2.0.zip` from the [Releases](https://github.com/gorman42/lms-multichannel-audio/releases/tag/v1.2.0) page.
2. Unzip into your LMS Plugins directory:
   `/var/lib/squeezeboxserver/Plugins/MultichannelAudio`
3. Restart Logitech Media Server:
   `sudo systemctl restart squeezeboxserver`

### Repository Installation
Add the following repository URL in LMS under **Settings > Plugins > Additional Repositories**:
```
https://raw.githubusercontent.com/gorman42/lms-multichannel-audio/main/repo.xml
```

---

## Supported Formats

| Container / Extension | Codec Payload | Bitstream Mode | Player Requirement |
| :--- | :--- | :--- | :--- |
| `.mka` | Dolby TrueHD Atmos | Passthrough (`mka://`) | Squeezelite (`feat/multichannel-bitstream`) |
| `.mka` | Dolby Digital Plus (E-AC-3) | Passthrough (`mka://`) | Squeezelite (`feat/multichannel-bitstream`) |
| `.mka` | DTS-HD Master Audio | Passthrough (`mka://`) | Squeezelite (`feat/multichannel-bitstream`) |
| `.m4a` / `.mp4` | E-AC-3 / EC-3 | Transmux (`# FT`) | Squeezelite (`feat/multichannel-bitstream`) |
| `.flac` | Multichannel LPCM (5.1 / 7.1) | Native LPCM | Squeezelite (`feat/multichannel-bitstream`) |

---

## License

Released under the GNU General Public License v3 (GPLv3).