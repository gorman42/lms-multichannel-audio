# LMS Multichannel & Bitstream Audio Plugin (`v1.2.2`)

`MultichannelAudio` is a Lyrion / Logitech Media Server (LMS 9.0+) plugin that unlocks discrete multichannel LPCM (up to 7.1) and raw IEC 61937 HDMI bitstream passthrough (Dolby Digital Plus Atmos, Dolby TrueHD Atmos, DTS-HD Master Audio / Auro-3D) for capable Squeezelite players, featuring pure-Perl Matroska (`.mka`) container parsing, binary cluster seeking, embedded `.mka` cover art rendering, and automatic stereo downmix fallback.

---

## Features in v1.2.2

- **Pure-Perl Matroska (`.mka`) Parsing & Bit-Level E-AC-3 Atmos Detection:** Complete EBML and Matroska demuxer written in pure Perl without requiring external binary tools (`mkvmerge` or `ffmpeg`), including an ETSI TS 102 366 / TS 103 420 bit-level BSI/JOC parser for accurate Dolby Digital Plus + Dolby Atmos (`ec3`) identification.
- **Embedded `.mka` Cover Art Integration:** Extracts embedded Matroska artwork during library scans (populating `COVER`, `FILESIZE`, and `TIMESTAMP` on virtual `mka://` tracks) and hooks `Slim::Utils::ImageResizer::resize` so embedded `.mka` cover art precaches and renders natively in the LMS Web UI despite `Audio::Scan` lacking Matroska support.
- **Instant Seeking (`Cues` + Binary Cluster Search) & Gapless Chapters:** Reads Matroska `Cues` elements when present and falls back to binary `Cluster` header search + header-only block skipping when `Cues` are absent, giving near-instant random chapter selection and seeking while preserving bit-accurate gapless chapter transitions and syncword alignment (`0xF8726FBA` for TrueHD, `0x0B77` for E-AC-3) on non-contiguous jumps.
- **Custom Protocol Handler (`mka://`):** Streams raw elementary bitstream frames directly to Squeezelite over HTTP/SlimProto (`-` zero-process passthrough) or pipes them via stdin (`# I`) into `ffmpeg` for stereo fallback.
- **Separated Transcoding & Resampling Engine (`custom-convert.conf`):**
  - `# I` (Stdin/Protocol Stream) rules handle `mka://` virtual chapter streams for raw bitstream passthrough, stereo `.mka` playback, and stereo FLAC downmixing.
  - `# FT` (Local File) rules handle standalone `.mka`, `.m4a`/`.mp4`, and multichannel `.flac` files with time-range seeking (`-ss` / `-t`).
  - `D:{RESAMPLE=-ar %d}` capability on all FLAC downmix rules automatically resamples high-rate (e.g., 96 kHz) multichannel sources to 48 kHz for S/PDIF-limited hardware players.
- **Stereo Downmix & Mixed Sync-Group Fallback:** Automatically downgrades multichannel/bitstream playback to 2-channel stereo FLAC whenever streaming to a non-multichannel endpoint or a synchronized multi-room group containing stereo players.

---

## Plugin Architecture

```
MultichannelAudio/
├── Plugin.pm                          # Main plugin initialization, sync-group intersection & ImageResizer hooks
├── install.xml                        # LMS plugin manifest (v1.2.2)
├── custom-convert.conf                # Transcoding, bitstream passthrough & resampling rules
├── custom-types.conf                  # MIME type mappings for MKA, E-AC-3, TrueHD, DTS-HD
├── Format/
│   ├── Matroska.pm                    # Pure-Perl Matroska EBML parser, E-AC-3 JOC parser & binary cluster searcher
│   └── Wrapper.pm                     # Multichannel wrapper format parser & MKA cover art extractor
└── ProtocolHandler/
    └── ProtocolHandler_Matroska.pm    # Pure-Perl mka:// stream handler & gapless chapter engine
```

---

## Verified Compatibility & Testing

Full end-to-end verification completed across both multichannel HDMI endpoints and stereo / legacy hardware endpoints:

- **Multichannel & Bitstream Endpoints:** Verified discrete 7.1 LPCM, Dolby TrueHD Atmos, E-AC-3 Atmos (standalone and chaptered `.mka` with embedded cover art), and DTS-HD MA / Auro-3D playback, seeking, track skipping, and gapless multi-chapter `.mka` album transitions.
- **Stereo & S/PDIF-Limited Endpoints (Squeezebox 2, DAC 32, WiiM Amp):** Verified automatic 2-channel FLAC downmixing, seeking, track skipping, chaptered `.mka` playback/seeking, and automatic 96 kHz -> 48 kHz resampling for optical S/PDIF (Squeezebox 2) across DTS-HD MA (`.m4a`), E-AC-3 (`.m4a` & `.mka`), standalone & chaptered TrueHD Atmos (`.mka`), and multichannel FLAC.
- **Mixed Multi-Room Sync Groups:** Verified synchronized playback between Atmos/bitstream-capable endpoints and stereo-only endpoints, cleanly falling back to stereo FLAC for the group without raw bitstream leakage.

---

## Installation

### Manual Installation
1. Download `MultichannelAudio-1.2.2.zip` from the [Releases](https://github.com/gorman42/lms-multichannel-audio/releases/tag/v1.2.2) page.
2. Unzip into your LMS Plugins directory:
   `/var/lib/squeezeboxserver/Plugins/MultichannelAudio`
3. Restart Lyrion / Logitech Media Server:
   `sudo systemctl restart lyrionmusicserver` (or `sudo systemctl restart squeezeboxserver`)

### Repository Installation
Add the following repository URL in LMS under **Settings > Plugins > Additional Repositories**:
```
[https://raw.githubusercontent.com/gorman42/lms-multichannel-audio/main/repo.xml](https://raw.githubusercontent.com/gorman42/lms-multichannel-audio/main/repo.xml)
```

---

## Supported Formats

| Container / Extension | Codec Payload | Multichannel Mode | Stereo Fallback Mode |
| :--- | :--- | :--- | :--- |
| `.mka` (single & chaptered) | Dolby TrueHD Atmos | Raw Passthrough (`mka://`, `# I`) | 2ch FLAC Downmix (`# I` / `# FT`) |
| `.mka` (single & chaptered) | Dolby Digital Plus Atmos (E-AC-3 JOC) | Raw Passthrough (`mka://`, `# I`) | 2ch FLAC Downmix (`# I` / `# FT`) |
| `.mka` (single & chaptered) | DTS-HD Master Audio | Raw Passthrough (`mka://`, `# I`) | 2ch FLAC Downmix (`# I` / `# FT`) |
| `.m4a` / `.mp4` | E-AC-3 / DTS-HD MA | Transmux (`# FT`) | 2ch FLAC Downmix + Resample (`# FT`) |
| `.flac` | Multichannel LPCM (5.1 / 7.1) | Native LPCM | 2ch FLAC Downmix + Resample |

---

## License

Released under the GNU General Public License v3 (GPLv3).
