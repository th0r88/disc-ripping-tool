# Disc Ripping Automation Tool

A robust bash script for automated DVD/Blu-ray backup and transcoding with disaster recovery support. Designed for headless Debian servers with a backup-first, transcode-later workflow.

## Features

- **Two-Phase Workflow**: Quickly backup multiple discs, then batch-transcode overnight
- **MakeMKV Integration**: Lossless backup for DVD and Blu-ray discs
- **Disaster Recovery**: Resume interrupted operations, recover orphaned backups, cleanup partial files
- **Queue Management**: Track pending transcodes, log completed items
- **Subtitle Processing**: Automatic extraction and OCR conversion for VobSub (DVD), PGS (Blu-ray), SRT, and ASS/SSA formats with multilingual support
- **TMDb Integration**: Automatic movie metadata lookup with Plex-compatible naming
- **NAS Support**: Automatic transfer to Plex media directory with verification

## System Requirements

- **OS**: Debian 13 (Trixie) or later (headless supported)
- **Storage**: 50GB+ free disk space (for backups + transcodes)
- **Drive**: DVD/Blu-ray drive (internal SATA or USB)
- **Network**: Internet access for TMDb API
- **CPU**: Multi-core recommended (encoding is CPU-intensive)

## Installation

### Step 1: Update System

```bash
sudo apt update && sudo apt upgrade -y
```

### Step 2: Install Required Dependencies

```bash
sudo apt install -y \
    handbrake-cli \
    mkvtoolnix \
    jq \
    curl \
    wget \
    libtesseract-dev \
    libleptonica-dev \
    tesseract-ocr \
    tesseract-ocr-all \
    libclang-dev \
    clang
```

**Note:** The script validates all dependencies at startup, including:
- HandBrakeCLI, mkvmerge, mkvextract, jq, curl
- subtile-ocr (installed via Cargo in Step 4)
- Preset JSON files in `presets/` directory

If any dependencies are missing, the script will display an error and exit.

### Step 3: Install Rust and Cargo

subtile-ocr is written in Rust and installed via Cargo:

```bash
# Install Rust toolchain (if not already installed)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Source the Cargo environment
source "$HOME/.cargo/env"

# Verify installation
rustc --version
cargo --version
```

### Step 4: Install subtile-ocr

```bash
# Install subtile-ocr from crates.io
cargo install subtile-ocr

# Verify installation
subtile-ocr --version
```

**Note**: subtile-ocr uses modern Tesseract 5.x and provides significantly better OCR accuracy than vobsub2srt, especially for non-English languages.

**Sudo Compatibility**: The script automatically detects subtile-ocr in your user's `~/.cargo/bin` directory even when running with sudo, so you don't need to install it system-wide.

### Step 5: Configure User Permissions

Add your user to the cdrom group and configure passwordless sudo for disc eject operations:

```bash
# Add user to cdrom and disk groups for disc access
sudo usermod -aG cdrom,disk $USER

# Create sudoers rule for disc eject operations (no password required)
echo "$USER ALL=(ALL) NOPASSWD: /bin/umount /dev/sr0" | sudo tee /etc/sudoers.d/disc-eject
echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/sg_start" | sudo tee -a /etc/sudoers.d/disc-eject
echo "$USER ALL=(ALL) NOPASSWD: /usr/bin/tee /sys/bus/usb/devices/*/authorized" | sudo tee -a /etc/sudoers.d/disc-eject
sudo chmod 0440 /etc/sudoers.d/disc-eject

# Log out and log back in for group changes to take effect
```

**Why this is needed:**
- The script can eject discs automatically between backups
- Multiple eject methods are used (standard eject, force unmount, USB reset)
- These operations require elevated privileges but you don't want to run the entire script as root
- The sudoers configuration allows specific eject commands without password prompts

**Security Note:** These rules only allow specific disc-related commands. The script itself runs as your normal user with your cargo binaries accessible.

### Step 6: Install MakeMKV (Optional but Recommended)

For lossless DVD backups with no quality loss, compile from source.

**⚠️ Important**: Use version **1.17.7** for Linux compatibility. Newer versions may have issues with certain USB drives.

```bash
# Install build dependencies
sudo apt install -y build-essential pkg-config libc6-dev \
    libssl-dev libexpat1-dev libavcodec-dev libgl1-mesa-dev \
    qtbase5-dev zlib1g-dev

# Download version 1.17.7 (recommended for Linux)
cd /tmp
wget https://www.makemkv.com/download/old/makemkv-oss-1.17.7.tar.gz
wget https://www.makemkv.com/download/old/makemkv-bin-1.17.7.tar.gz

# Build and install makemkv-oss
tar xzf makemkv-oss-1.17.7.tar.gz
cd makemkv-oss-1.17.7
./configure
make
sudo make install

# Build and install makemkv-bin
cd /tmp
tar xzf makemkv-bin-1.17.7.tar.gz
cd makemkv-bin-1.17.7
make
sudo make install

# Create MakeMKV settings directory and add registration key
mkdir -p ~/.MakeMKV
cat > ~/.MakeMKV/settings.conf << 'EOF'
app_Key = "T-your-license-key-here"
EOF

# Verify installation
makemkvcon -r info disc:0
```

**Note**: Replace `T-your-license-key-here` with your actual MakeMKV license key. Get a free beta key from https://forum.makemkv.com/forum/viewtopic.php?f=5&t=1053

#### Optional: Flash Verbatim 43888 BU40N Firmware (Required for LibreDrive)

If you have a **Verbatim Ultra HD 4K Blu-ray Writer (Model 43888)** with the **BU40N chipset**, you need to downgrade the firmware to enable LibreDrive support:

```bash
# Check what chipset you have
sudo apt install -y sg3-utils
sudo sg_inq /dev/sr0

# If output shows "BD-RE BU40N" with firmware 1.05 or higher, you need to flash
```

**⚠️ WARNING**: Firmware flashing can **brick your drive** if interrupted or done incorrectly. Only proceed if:
- Your laptop is **plugged into AC power**
- You understand the **risks**
- You have the **correct firmware file**
- You will **NOT interrupt** the process

**Flashing Instructions:**

```bash
# Navigate to MakeMKV source directory
cd /tmp/makemkv-bin-1.17.7/src

# Find the BU40N firmware file (should be included)
ls -la | grep -i bu40n
# Look for: HL-DT-ST-BD-RE_BU40N-1.03-NM00000-211810241934.bin

# Flash the drive (this takes 2-5 minutes)
makemkvcon f -d /dev/sr0 rawflash enc -i HL-DT-ST-BD-RE_BU40N-1.03-NM00000-211810241934.bin

# When prompted, type "yes" to confirm

# DO NOT:
# - Unplug the USB drive
# - Close the terminal
# - Shut down the computer
# - Press Ctrl+C

# Wait for "Done successfully" message

# Verify firmware downgrade
sudo sg_inq /dev/sr0 | grep "Product revision"
# Should show: Product revision level: 1.03

# Test MakeMKV with a disc
makemkvcon -r info disc:0
# Should show: "Using LibreDrive mode (v06.3 id=...)"
```

**Why this is needed:**
- Verbatim changed chipsets in Model 43888 without changing the model number
- The **Pioneer UD04** chipset works out-of-box (no flash needed)
- The **BU40N chipset** ships with firmware 1.05 which blocks LibreDrive
- Downgrading to firmware 1.03MK enables LibreDrive for lossless ripping

**Reference**: https://github.com/nxyzo/Flashing-Verbatim-43888-BU40N-to-1.03MK

### Step 7: Verify Tesseract Language Data

Tesseract language packs were installed in Step 3 with `tesseract-ocr-all`. Verify installation:

```bash
# List installed Tesseract languages
tesseract --list-langs

# Should show 100+ languages including:
# eng (English), fra (French), deu (German), spa (Spanish), etc.
```

**Note**: The script will automatically use system Tesseract with the installed language data. No additional setup required.

**Supported Languages** (100+): All languages available in Debian's `tesseract-ocr-all` package, including all European languages, Asian languages, and more.

## Configuration

### Step 1: Make Script Executable

```bash
chmod +x disc-ripping.sh
```

### Step 2: Get TMDb API Key

1. Create account at https://www.themoviedb.org/signup
2. Go to https://www.themoviedb.org/settings/api
3. Request API key (choose "Developer")
4. Copy "API Key (v3 auth)" value

### Step 3: Edit Script Configuration

```bash
nano disc-ripping.sh
```

Update these variables (lines 26-37):

```bash
# TMDb API Key (required - get from https://www.themoviedb.org/settings/api)
TMDB_API_KEY="API_KEY_GOES_HERE"  # Replace with your API key

# Working directory (where backups are stored)
WORK_DIR="$HOME/disc-ripping"

# NAS destination for final files
NAS_MOVIES="/mnt/Plex/Movies"

# Disc device (usually /dev/sr0)
DISC_DEVICE="/dev/sr0"
```

**Note**: Encoding presets are now selected per-disc during the backup phase (Mode 1). See [Operating Modes](#operating-modes) for details.

### Step 4: Verify Disc Drive Detection

```bash
# Check disc device
ls -la /dev/sr* /dev/cdrom*

# Test drive access with HandBrake
HandBrakeCLI -i /dev/sr0 --scan 2>&1 | head -20

# Verify you're in cdrom group
groups  # Should include 'cdrom'
```

## Quick Start

### First Run

```bash
./disc-ripping.sh
```

The script will detect your disc and guide you through the backup and encoding process.

### Debug Mode (Keep Temporary Files)

```bash
./disc-ripping.sh --keep-temp
```

This flag changes several behaviors for debugging and testing:

1. **Backup files preserved** - MakeMKV backup files remain in `temp/backups/` directory
2. **Queue entries preserved** - Items stay in `transcode_queue.txt` after processing (not deleted)
3. **Re-transcoding enabled** - Process the same backup multiple times with different presets
4. **Temporary data kept** - Intermediate files and logs preserved

**Use cases:**
- Testing different encoding presets on the same backup
- Debugging subtitle extraction issues
- Analyzing HandBrake encoding behavior

**Important:** When using `--keep-temp`, you must manually clean up the queue after testing:
```bash
# Remove first entry from queue after re-transcoding
sed -i '1d' temp/transcode_queue.txt

# Or remove all accumulated entries (if you tested multiple times)
rm temp/transcode_queue.txt
```

**Queue Accumulation Warning:**

When using `--keep-temp`, queue entries are **never deleted**. This means:
- Each backup adds a new entry to the queue
- Each transcode run with `--keep-temp` preserves all entries
- Running without `--keep-temp` later will process **all accumulated entries** (including duplicates from testing)

**Example scenario:**
1. Backup 2 discs with `--keep-temp` → Queue has 2 entries
2. Transcode with `--keep-temp` → Queue still has 2 entries (preserved)
3. Backup same 2 discs again with `--keep-temp` → Queue now has 4 entries (duplicates!)
4. Transcode without `--keep-temp` → Processes all 4 entries (2 succeed, 2 fail with "backup not found")

**Solution:** Always clean the queue after `--keep-temp` testing:
```bash
# Check queue contents
cat temp/transcode_queue.txt

# Remove duplicate entries or delete entire queue
rm temp/transcode_queue.txt
```

**Note on Crash Recovery:** This design does NOT conflict with crash recovery. When running without `--keep-temp`, queue entries are removed only after successful processing, so crashes preserve unprocessed items for resume.

## Usage

### Operating Modes

The script offers 5 modes:

1. **Backup Disc to queue** - Quick backup (10-15 min/disc), adds to transcode queue
2. **Process transcode queue** - High-quality encode + subtitles + NAS transfer
3. **Process subtitles only** - Extract/convert subtitles from existing MKV
4. **Recovery mode** - Resume interrupted operations, cleanup partial files
0. **Exit**

### Workflow 1: Backup Multiple Discs, Transcode Later (Recommended)

**Phase 1: Backup all discs (daytime)**

```bash
./disc-ripping.sh
# Select Mode 1
# Insert disc (DVD or Blu-ray)
# Enter movie title (e.g., "The Matrix")
# Select correct movie from TMDb search
# Select encoding preset (DVD/BluRay/4K)
# Wait 10-15 minutes for lossless MakeMKV backup
# When complete, choose "1. Backup another disc" (disc auto-ejects)
# Insert next disc and repeat
# When done, choose "0. Exit"
```

**Phase 2: Transcode queue (overnight)**

```bash
./disc-ripping.sh
# Select Mode 2 (disc auto-ejects)
# Leave running overnight
# For each queued item:
#   1. Extracts subtitles from backup file (before encoding)
#   2. Encodes video with selected preset
#   3. Transfers to NAS
# Processes entire queue automatically
```

**How Subtitle Extraction Works:**

Subtitles are extracted from the MakeMKV backup file **before encoding starts**. This is important because:
- The backup file contains all original subtitle tracks (VobSub, PGS, SRT, ASS/SSA)
- HandBrake may not preserve all subtitle tracks during encoding
- Image-based formats (VobSub, PGS) are OCR-converted to SRT using subtile-ocr
- Text-based formats (SRT, ASS/SSA) are copied directly
- If a subtitle language isn't available in Tesseract, the script automatically falls back to English OCR

**Encoding Progress:**

During encoding, HandBrake displays real-time progress updates:
- `Encoding: task X of Y, X.XX %` - Current encoding percentage
- Average encoding speed (fps)
- ETA and time remaining
- Progress updates with carriage return for clean display

### Workflow 2: Extract Subtitles from Existing Files

```bash
./disc-ripping.sh
# Select Mode 3
# Choose MKV file
# Subtitles extracted to output directory
```

### Workflow 3: Recover from Interrupted Operation

```bash
./disc-ripping.sh
# Select Mode 4
# Choose recovery option:
#   1. Clean up incomplete and partial files
#   2. Recover orphaned backups to queue
#   3. Resume transcode queue
#   4. Full cleanup (delete all backups)
```

## File Structure

```
/home/user/disc-ripping/
├── disc-ripping.sh                    # Main script
├── disc-rip.log                      # Full log file
├── temp/
│   ├── backups/                      # Raw disc backups (4-8GB for DVD, 15-50GB for Blu-ray)
│   │   └── imdb-tt0133093_raw.mkv
│   ├── transcode_queue.txt           # Pending transcodes
│   ├── transcode_completed.log       # Completed items log
│   └── current_operation.state       # Crash detection state
└── output/                            # Final encoded files
    └── The Matrix (1999) {imdb-tt0133093}/
        ├── The Matrix (1999) {imdb-tt0133093}.mkv
        └── The Matrix (1999) {imdb-tt0133093}.en.srt
```

## Troubleshooting

### MakeMKV Hangs Forever

**Symptom**: Script freezes at "Scanning disc with MakeMKV..."

**Solution 1: Check if you have the correct drive chipset**

If you have a **Verbatim Ultra HD 4K (Model 43888)** with the **BU40N chipset** (not the Pioneer UD04), you need to downgrade the firmware:

```bash
# Check what chipset you have
sudo apt install -y sg3-utils
sudo sg_inq /dev/sr0

# If you see "BD-RE BU40N", you need to flash firmware to 1.03MK
# Download firmware (included in MakeMKV 1.17.7)
cd /tmp/makemkv-bin-1.17.7/src

# Find the BU40N firmware file
ls -la | grep -i bu40n

# Flash the drive (BE CAREFUL - this can brick your drive!)
# Make sure laptop is plugged in and DO NOT interrupt
makemkvcon f -d /dev/sr0 rawflash enc -i HL-DT-ST-BD-RE_BU40N-1.03-NM00000-211810241934.bin
# Type "yes" when prompted

# Verify firmware downgrade
sudo sg_inq /dev/sr0 | grep "Product revision"
# Should show: Product revision level: 1.03

# Test MakeMKV
makemkvcon -r info disc:0
```

**Solution 2: If firmware flash doesn't work**

MakeMKV is now required for backup mode. If MakeMKV doesn't work with your drive after firmware flash, you may need a different drive model.

### Disc Device Not Found

**Symptom**: `"Disc device not found: /dev/sr0"`

**Solution**:
```bash
# Check if drive is detected
lsblk
ls -la /dev/sr* /dev/cdrom*

# If USB drive, it might be /dev/sr1 or /dev/scd0
# Update DISC_DEVICE in script (line 37):
DISC_DEVICE="/dev/sr1"
```

### Permission Denied When Accessing Disc

**Symptom**: `"Permission denied"` errors when scanning disc

**Solution**:
```bash
# Add user to cdrom group
sudo usermod -aG cdrom $USER

# Log out and back in, then verify
groups  # Should show 'cdrom'

# Check device permissions
ls -la /dev/sr0  # Should show 'brw-rw----+ 1 root cdrom' or 'brw-rw---- 1 root disk'
```

### No Write Permission to NAS

**Symptom**: `"No write permission to NAS: /mnt/Plex/temp"`

**Solution**:
```bash
# Check if NAS is mounted
df -h | grep Plex

# Mount NAS manually (example with CIFS/SMB)
sudo mkdir -p /mnt/Plex
sudo mount -t cifs //nas-ip/Plex /mnt/Plex -o username=user,password=pass

# Or add to /etc/fstab for auto-mount
echo "//nas-ip/Plex /mnt/Plex cifs username=user,password=pass,uid=1000,gid=1000 0 0" | sudo tee -a /etc/fstab

# Or skip NAS transfer (files stay in output directory)
# Answer "n" when script asks "Continue anyway?"
```

### Subtitle OCR Fails

**Symptom**: `"Tesseract data not found for 'fra', falling back to English"`

**Note**: The script automatically falls back to English OCR when a subtitle language isn't available in Tesseract. This is normal behavior and subtitle extraction will continue using English.

**Solution** (if you want to install the specific language):
```bash
# Check installed Tesseract languages
tesseract --list-langs

# Install specific language pack if missing
sudo apt install tesseract-ocr-fra  # For French
sudo apt install tesseract-ocr-deu  # For German
sudo apt install tesseract-ocr-spa  # For Spanish

# Or install all languages
sudo apt install tesseract-ocr-all

# Verify installation
tesseract --list-langs | grep fra
```

### Interrupted Operation Detected

**Symptom**: Warning about interrupted operation on startup

**Solution**:
```bash
# Use Mode 4 (Recovery mode)
./disc-ripping.sh
# Select Mode 4
# Choose appropriate recovery option:
#   - Option 1: Clean up incomplete/partial files
#   - Option 2: Recover orphaned backups
#   - Option 3: Resume transcode queue
```

### HandBrake Error: "No title found"

**Symptom**: HandBrake can't find disc titles

**Solution**:
```bash
# Check if disc is readable
dd if=/dev/sr0 of=/dev/null bs=2048 count=1

# Try ejecting and reinserting disc
eject /dev/sr0
# Reinsert disc and wait 10 seconds

# Check for copy protection (script should handle this)
# Some discs require libdvdcss2:
sudo apt install libdvd-pkg
sudo dpkg-reconfigure libdvd-pkg
```

## Performance Expectations

### Backup Phase (Mode 1)

| Media Type | Time per Disc | File Size | Quality Loss |
|------------|---------------|-----------|--------------|
| DVD | 10-15 min | 4-8 GB | None (lossless) |
| Blu-ray | 20-40 min | 15-35 GB | None (lossless) |
| 4K UHD Blu-ray | 40-90 min | 30-100 GB | None (lossless) |

### Transcode Phase (Mode 2)

| Preset | Time per Movie | Notes |
|--------|----------------|-------|
| DVD to x264 MKV (CRF 20) | 60-90 min | SD/DVD content |
| BluRay to x264 MKV (CRF 24) | 90-120 min | 1080p content |
| BluRay 4K to x265 MKV (CRF 24) | 120-180 min | 4K UHD content |
| Subtitle OCR | 2-5 min/language | Per subtitle track |
| NAS Transfer | 2-10 min | Depends on network speed |

**Total time for 10 discs** (mixed DVDs/Blu-rays):
- Backup: 3-6 hours (Phase 1, during daytime)
- Transcode: 12-20 hours (Phase 2, overnight)

**Note:** Encoding times vary significantly based on:
- CPU performance (single-threaded speed and core count)
- Preset complexity (veryslow vs medium, x264 vs x265)
- Source disc quality and bitrate
- Disc read speed (internal SATA vs USB)
- System load and thermal throttling

## Disaster Recovery

The script automatically handles common failure scenarios:

### Auto-Detected Issues

- ✅ **Incomplete backups** (< 100MB) - Automatically deleted on Mode 1 start
- ✅ **Orphaned backups** - Files in backup directory not in queue
- ✅ **Partial encoded files** (< 50MB) - Detected and cleaned up
- ✅ **Crashed operations** - State file detects hung operations (> 5 min old)
- ✅ **Missing backup files** - Queue items with deleted backups are skipped

### Recovery Options (Mode 4)

1. **Clean up incomplete and partial files** - Deletes incomplete backups and partial encodes
2. **Recover orphaned backups to queue** - Interactive recovery with metadata entry
3. **Resume transcode queue** - Continues from where it left off
4. **Full cleanup** - Nuclear option: delete everything (requires confirmation)

### State Files

- **`transcode_queue.txt`** - List of pending transcodes (removed line-by-line as processed unless `--keep-temp` is used)
  - Format: `backup_path|movie_title|year|imdb_id|preset_identifier`
  - Example: `/home/jan/disc-ripping/temp/backups/imdb-tt0133093_raw.mkv|The Matrix|1999|tt0133093|custom_x264_mkv2`

- **`transcode_completed.log`** - Permanent record of all processed items (success/failure)

- **`current_operation.state`** - Tracks current operation for crash detection
  - Format: `operation|unix_timestamp|file_path|progress_percentage`
  - Example: `encoding|1697845200|/path/to/file.mkv|0`
  - Crash detection: Operations older than 5 minutes (300 seconds) are considered stalled
  - Updated during: backup, subtitles, encoding, transfer operations
  - Deleted on successful completion

## Advanced Configuration

### Encoding Presets

The script uses external JSON preset files for HandBrake encoding. Presets are stored in the `presets/` directory and you select one per-disc during backup (Mode 1):

1. **DVD to x264 MKV** (SD/DVD content) - `presets/DVD_to_x264_MKV.json`
   - CRF 20, x264 veryslow, film tune
   - Time: ~60-90 minutes per movie

2. **BluRay to x264 MKV** (1080p content) - `presets/BluRay_to_x264_MKV.json`
   - CRF 24, x264 veryslow, film tune
   - Time: ~90-120 minutes per movie

3. **BluRay 4K to x265 MKV** (4K UHD content) - `presets/BluRay_4K_to_x265.json`
   - CRF 24, x265 10-bit slow
   - Time: ~120-180 minutes per movie

**Customizing Presets:**

The script validates all preset files exist at startup. To customize encoding settings:

1. Edit the JSON preset file in the `presets/` directory
2. Modify HandBrake parameters like `VideoQualitySlider` (CRF), `VideoPreset` (encoding speed), `VideoEncoder` (codec)
3. Test with a sample file: `HandBrakeCLI --preset-import-file presets/DVD_to_x264_MKV.json --preset "DVD to x264 MKV" -i input.mkv -o test.mkv`

For JSON preset format documentation, see: https://handbrake.fr/docs/en/latest/technical/official-presets.html

### Custom Working Directory

```bash
# Edit script (line 34)
WORK_DIR="/mnt/storage/dvd-ripping"

# Create directory structure
mkdir -p /mnt/storage/dvd-ripping/{temp/backups,output}
```

### Automate Queue Processing (Advanced)

**Note:** The script requires interactive mode selection at startup. For automated/unattended operation, you would need to modify the script to accept a mode as a command-line argument (e.g., `./disc-ripping.sh --mode=2`).

If you modify the script to support non-interactive mode, you can then use systemd or cron for automation. Example systemd timer approach:

1. Add CLI mode support to script (modify script to accept `--mode=N` argument)
2. Create systemd service pointing to `disc-ripping.sh --mode=2`
3. Create systemd timer to trigger service at desired time (e.g., 2:00 AM daily)

Without CLI mode support, the script must be run interactively.

## Command-Line Options

```bash
./disc-ripping.sh [OPTIONS]

OPTIONS:
  --keep-temp     Preserve backup files and temporary data after successful operations
```

**Example**:

```bash
# Keep backup files and temp data for debugging
./disc-ripping.sh --keep-temp
```

## Dependencies

### Required

| Package | Purpose | Install |
|---------|---------|---------|
| handbrake-cli | DVD ripping and encoding | `apt install handbrake-cli` |
| mkvtoolnix | MKV manipulation (mkvmerge/mkvextract) | `apt install mkvtoolnix` |
| subtile-ocr | Subtitle OCR for VobSub (DVD) and PGS (Blu-ray) image formats to SRT. Also handles text-based SRT and ASS/SSA formats. | `cargo install subtile-ocr` |
| tesseract-ocr | OCR engine for subtitle conversion | `apt install tesseract-ocr tesseract-ocr-all` |
| jq | JSON parsing for TMDb API | `apt install jq` |
| curl | HTTP requests for TMDb API with retry logic (3 attempts, 5s delay on HTTP 429 rate limiting) | `apt install curl` |

### Optional

| Package | Purpose | Install |
|---------|---------|---------|
| makemkvcon | Lossless DVD backup | `apt install makemkv-bin makemkv-oss` or compile from source |

## Known Limitations

- ⚠️ **USB drive compatibility**: Some USB Blu-ray drives may require firmware downgrade for MakeMKV LibreDrive support
- ⚠️ **OCR accuracy**: Subtitle OCR is not 100% accurate (Tesseract limitations)
- ⚠️ **Copy protection**: Some discs require `libdvdcss2` for decryption
- ⚠️ **Storage requirements**: 4K Blu-ray backups can be 50-100GB each
- ⚠️ **Headless operation**: Requires all configuration done via text editor (no GUI)

## FAQ

**Q: Can I run this on a headless server?**
A: Yes! The script is fully text-based and requires no GUI.

**Q: Does it work with Blu-ray discs?**
A: Yes! MakeMKV supports DVD, Blu-ray, and 4K UHD Blu-ray. The script offers 3 encoding presets optimized for each format.

**Q: How much disk space do I need?**
A: For 10 DVDs: ~50GB (backups) + ~40GB (final files) = 90GB minimum. For Blu-rays, budget 200-400GB. Backups are deleted after successful transcode.

**Q: Can I process multiple discs simultaneously?**
A: No, the script processes one disc at a time. However, you can backup multiple discs quickly (Mode 1), then transcode them all overnight (Mode 2).

**Q: What if I don't have a NAS?**
A: Files will remain in the `output/` directory. You can skip NAS transfer when prompted.

**Q: Can I use a different TMDb API key for each run?**
A: The API key is hardcoded in the script. Edit it once in the configuration section.

**Q: Does it support dual-layer DVDs (DVD-9) and dual-layer Blu-rays?**
A: Yes, MakeMKV supports all DVD and Blu-ray formats including dual-layer.

**Q: What happens if my computer crashes during encoding?**
A: Use Mode 4 (Recovery mode) to clean up partial files and resume from the queue.

## License

This script is provided as-is for personal use and backuping of legally obtained discs. Dependencies used under their respective licenses:

- **HandBrake**: GPL-2.0 License
- **MakeMKV**: Proprietary (free beta with registration)
- **mkvtoolnix**: GPL-2.0 License
- **subtile-ocr**: MIT License

Movie metadata provided by **The Movie Database (TMDb)** API.

## Credits

- HandBrake Team - https://handbrake.fr/
- MakeMKV - https://www.makemkv.com/
- mkvtoolnix - https://mkvtoolnix.download/
- subtile-ocr - https://github.com/FedericoCarboni/subtile-ocr
- The Movie Database (TMDb) - https://www.themoviedb.org/
