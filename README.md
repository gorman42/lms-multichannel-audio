# Multichannel & Bitstream Audio for Lyrion Music Server

A Lyrion Music Server (LMS 9.0+) plugin enabling discrete multichannel LPCM playback (3.0 to 7.1) and raw IEC 61937 HDMI bitstream passthrough (**Dolby Digital Plus Atmos**, **Dolby TrueHD Atmos**, and **DTS-HD MA / Auro-3D**) for capable Squeezelite clients, with automatic stereo downmix fallback for stereo-only players and mixed sync groups.

## Installation via LMS Plugin Repository

1. Open **LMS Web UI → Settings → Plugins**.
2. Add the repository URL under **Additional Repositories**:
   `https://raw.githubusercontent.com/gorman42/lms-multichannel-audio/main/repo.xml`
3. Click **Apply**, enable **Multichannel & Bitstream Audio**, and restart LMS.
