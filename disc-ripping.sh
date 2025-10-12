#!/bin/bash

# Disc Ripping Automation Tool
# Usage: ./disc-ripping.sh [--keep-temp]

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Parse command line arguments
KEEP_TEMP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-temp)
            KEEP_TEMP=true
            echo "Mode: Preserving temporary files for debugging"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--keep-temp]"
            exit 1
            ;;
    esac
done

# Configuration
TMDB_API_KEY="API_KEY_GOES_HERE"  # Replace with your TMDb API key
WORK_DIR="$HOME/disc-ripping"
TEMP_DIR="$WORK_DIR/temp"
BACKUP_DIR="$TEMP_DIR/backups"
QUEUE_FILE="$TEMP_DIR/transcode_queue.txt"
STATE_FILE="$TEMP_DIR/current_operation.state"
COMPLETED_LOG="$TEMP_DIR/transcode_completed.log"
OUTPUT_DIR="$WORK_DIR/output"
NAS_MOVIES="/mnt/Plex/Movies"
LOG_FILE="$WORK_DIR/disc-rip.log"
DISC_DEVICE="/dev/sr0"

# Preset files (relative to script location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESET_DVD="$SCRIPT_DIR/presets/DVD_to_x264_MKV.json"
PRESET_BLURAY_1080P="$SCRIPT_DIR/presets/BluRay_to_x264_MKV.json"
PRESET_BLURAY_4K="$SCRIPT_DIR/presets/BluRay_4K_to_x265.json"

# Retry settings
MAX_RETRIES=3
RETRY_DELAY=5

# Language codes for subtitle naming (ISO 639-2 to ISO 639-1)
declare -A LANG_CODES=(
    ["alb"]="sq"  # Albanian
    ["arm"]="hy"  # Armenian
    ["baq"]="eu"  # Basque
    ["bel"]="be"  # Belarusian
    ["bos"]="bs"  # Bosnian
    ["bul"]="bg"  # Bulgarian
    ["cat"]="ca"  # Catalan
    ["hrv"]="hr"  # Croatian
    ["cze"]="cs"  # Czech
    ["dan"]="da"  # Danish
    ["dut"]="nl"  # Dutch
    ["eng"]="en"  # English
    ["est"]="et"  # Estonian
    ["fin"]="fi"  # Finnish
    ["fre"]="fr"  # French
    ["geo"]="ka"  # Georgian
    ["ger"]="de"  # German
    ["gre"]="el"  # Greek
    ["hun"]="hu"  # Hungarian
    ["ice"]="is"  # Icelandic
    ["gle"]="ga"  # Irish
    ["ita"]="it"  # Italian
    ["lav"]="lv"  # Latvian
    ["lit"]="lt"  # Lithuanian
    ["ltz"]="lb"  # Luxembourgish
    ["mac"]="mk"  # Macedonian
    ["mlt"]="mt"  # Maltese
    ["nor"]="no"  # Norwegian
    ["pol"]="pl"  # Polish
    ["por"]="pt"  # Portuguese
    ["rum"]="ro"  # Romanian
    ["rus"]="ru"  # Russian
    ["scc"]="sr"  # Serbian
    ["slo"]="sk"  # Slovak
    ["slv"]="sl"  # Slovenian
    ["spa"]="es"  # Spanish
    ["swe"]="sv"  # Swedish
    ["tur"]="tr"  # Turkish
    ["ukr"]="uk"  # Ukrainian
    ["wel"]="cy"  # Welsh
)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1"
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "$msg" >> "$LOG_FILE"
}

log_warn() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $1"
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "$msg" >> "$LOG_FILE"
}

log_error() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    echo -e "${RED}[ERROR]${NC} $1"
    echo "$msg" >> "$LOG_FILE"
}

log_debug() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] [DEBUG] $1"
    echo -e "${BLUE}[DEBUG]${NC} $1"
    echo "$msg" >> "$LOG_FILE"
}

# Error trap
error_exit() {
    log_error "Script failed at line $1"
    cleanup
    exit 1
}

trap 'error_exit $LINENO' ERR

# Eject disc function with multiple methods
eject_disc() {
    log_info "Ejecting current disc..."

    # Try multiple eject methods
    local ejected=false

    # Method 1: Standard eject
    if eject "$DISC_DEVICE" 2>/dev/null; then
        log_info "Disc ejected successfully"
        ejected=true
    fi

    # Method 2: Force unmount and eject
    if [ "$ejected" = false ]; then
        log_info "Trying force unmount..."
        sudo umount "$DISC_DEVICE" 2>/dev/null || true
        if eject -v "$DISC_DEVICE" 2>/dev/null; then
            log_info "Disc ejected successfully (forced)"
            ejected=true
        fi
    fi

    # Method 3: Use sg_start to stop the drive
    if [ "$ejected" = false ]; then
        log_info "Trying sg_start stop/eject..."
        if command -v sg_start &>/dev/null; then
            sudo sg_start --stop "$DISC_DEVICE" 2>/dev/null || true
            sleep 1
            sudo sg_start --eject "$DISC_DEVICE" 2>/dev/null || true
            sleep 1
            if eject "$DISC_DEVICE" 2>/dev/null; then
                log_info "Disc ejected successfully (sg_start)"
                ejected=true
            fi
        fi
    fi

    # Method 4: Reset USB device (last resort)
    if [ "$ejected" = false ]; then
        log_warn "Standard eject methods failed"
        log_info "Attempting USB device reset..."

        # Find USB device path for the optical drive
        local usb_device=$(udevadm info -q path -n "$DISC_DEVICE" 2>/dev/null | grep -o 'usb[0-9]*/[0-9-]*:[0-9.]*' | head -1)

        if [ -n "$usb_device" ]; then
            local usb_path="/sys/bus/usb/devices/$usb_device"
            if [ -d "$usb_path" ]; then
                log_info "Found USB device: $usb_device"
                log_info "Resetting USB device..."
                echo 0 | sudo tee "$usb_path/authorized" > /dev/null 2>&1
                sleep 2
                echo 1 | sudo tee "$usb_path/authorized" > /dev/null 2>&1
                sleep 3
                log_info "USB device reset complete"
                ejected=true
            fi
        else
            log_warn "Could not find USB device path"
            log_info "Please manually unplug and replug the USB drive"
        fi
    fi

    return 0
}

# Cleanup function
cleanup() {
    if [ "$KEEP_TEMP" = true ]; then
        log_info "Preserving temporary files for debugging in: $TEMP_DIR"
        log_info "Output files preserved in: $OUTPUT_DIR"
        log_warn "Remember to manually clean temp directory when done: rm -rf $TEMP_DIR/*"
    else
        log_info "Cleaning up temporary files..."
        if [ -d "$TEMP_DIR" ]; then
            # Clean temp directory but preserve backups, queue, completed log, and state
            find "$TEMP_DIR" -maxdepth 1 -type f ! -name "transcode_queue.txt" ! -name "transcode_completed.log" ! -name "current_operation.state" -delete
            # Don't remove backups directory
        fi
        log_info "Output files preserved in: $OUTPUT_DIR"
        if [ -f "$QUEUE_FILE" ]; then
            log_info "Queue file preserved: $QUEUE_FILE"
        fi
        if [ -f "$COMPLETED_LOG" ] && [ -s "$COMPLETED_LOG" ]; then
            log_info "Completed log preserved: $COMPLETED_LOG"
        fi
        if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
            log_info "Backup files preserved in: $BACKUP_DIR"
        fi
    fi
}

# Check dependencies
check_dependencies() {
    log_info "Checking dependencies..."
    local missing_deps=()

    local required_commands=("HandBrakeCLI" "mkvmerge" "mkvextract" "jq" "curl")

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    # Check subtile-ocr (check common cargo paths for sudo compatibility)
    if ! command -v subtile-ocr &> /dev/null; then
        # When running with sudo, check common cargo installation paths
        if [ -n "$SUDO_USER" ]; then
            local user_home=$(eval echo ~"$SUDO_USER")
            if [ -x "$user_home/.cargo/bin/subtile-ocr" ]; then
                # Add to PATH for this session
                export PATH="$user_home/.cargo/bin:$PATH"
                log_info "Found subtile-ocr in $user_home/.cargo/bin"
            else
                missing_deps+=("subtile-ocr (install with: cargo install subtile-ocr)")
            fi
        else
            missing_deps+=("subtile-ocr (install with: cargo install subtile-ocr)")
        fi
    fi

    # Check tesseract
    if ! command -v tesseract &> /dev/null; then
        missing_deps+=("tesseract-ocr")
    fi

    # Check makemkvcon (required for backup mode)
    if command -v makemkvcon &> /dev/null; then
        log_info "makemkvcon found - ready for lossless backups"
        MAKEMKV_AVAILABLE=true
    else
        log_warn "makemkvcon not found - will use HandBrake fast encode for backups"
        log_warn "Install MakeMKV for faster, lossless backups"
        MAKEMKV_AVAILABLE=false
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_error "Please install missing tools and try again"
        exit 1
    fi

    # Check HandBrake preset files
    local missing_presets=()
    if [ ! -f "$PRESET_DVD" ]; then
        missing_presets+=("$PRESET_DVD")
    fi
    if [ ! -f "$PRESET_BLURAY_1080P" ]; then
        missing_presets+=("$PRESET_BLURAY_1080P")
    fi
    if [ ! -f "$PRESET_BLURAY_4K" ]; then
        missing_presets+=("$PRESET_BLURAY_4K")
    fi

    if [ ${#missing_presets[@]} -ne 0 ]; then
        log_error "Missing HandBrake preset files:"
        for preset in "${missing_presets[@]}"; do
            log_error "  - $preset"
        done
        log_error "Please ensure preset files are in the 'presets' directory"
        exit 1
    fi

    log_info "All required dependencies and preset files found"
}

# Check NAS mount
check_nas_mount() {
    log_info "Checking NAS mount..."
    
    if [ ! -d "$NAS_MOVIES" ]; then
        log_error "NAS mount point not found: $NAS_MOVIES"
        log_error "Please mount your NAS and try again"
        return 1
    fi
    
    # Test write permission
    if ! touch "$NAS_MOVIES/.write_test" 2>/dev/null; then
        log_error "No write permission to NAS: $NAS_MOVIES"
        rm -f "$NAS_MOVIES/.write_test" 2>/dev/null
        return 1
    fi
    
    rm -f "$NAS_MOVIES/.write_test"
    log_info "NAS mount is accessible and writable"
    return 0
}

# Check disk space
check_disk_space() {
    local path="$1"
    local required_gb="$2"
    
    local available_kb=$(df -k "$path" | tail -1 | awk '{print $4}')
    local available_gb=$((available_kb / 1024 / 1024))
    
    log_debug "Available space in $path: ${available_gb}GB"
    
    if [ "$available_gb" -lt "$required_gb" ]; then
        log_error "Insufficient disk space in $path"
        log_error "Required: ${required_gb}GB, Available: ${available_gb}GB"
        return 1
    fi
    
    return 0
}

# Sanitize filename
sanitize_filename() {
    local filename="$1"
    # Remove or replace invalid characters
    echo "$filename" | sed 's/[<>:"|?*]/_/g' | sed 's/[\/]/-/g'
}

# Search TMDb with retry logic
search_tmdb() {
    local query="$1"
    local encoded_query=$(echo "$query" | jq -sRr @uri)
    local url="https://api.themoviedb.org/3/search/movie?api_key=$TMDB_API_KEY&query=$encoded_query"
    local attempt=1
    local results=""
    
    log_info "Searching TMDb for: $query"
    
    # Check internet connectivity (simple ping test)
    if ! curl -s --max-time 5 https://api.themoviedb.org > /dev/null 2>&1; then
        log_error "No internet connection or TMDb is unreachable"
        return 1
    fi
    
    # Retry logic for API calls
    while [ $attempt -le $MAX_RETRIES ]; do
        results=$(curl -s -w "\n%{http_code}" "$url")
        local http_code=$(echo "$results" | tail -n1)
        local body=$(echo "$results" | sed '$d')
        
        if [ "$http_code" = "200" ]; then
            break
        elif [ "$http_code" = "401" ]; then
            log_error "Invalid TMDb API key"
            return 1
        elif [ "$http_code" = "429" ]; then
            log_warn "Rate limited by TMDb. Waiting ${RETRY_DELAY}s before retry $attempt/$MAX_RETRIES..."
            sleep $RETRY_DELAY
        else
            log_warn "TMDb API returned HTTP $http_code. Retry $attempt/$MAX_RETRIES..."
            sleep $RETRY_DELAY
        fi
        
        ((attempt++))
    done
    
    if [ $attempt -gt $MAX_RETRIES ]; then
        log_error "Failed to connect to TMDb after $MAX_RETRIES attempts"
        return 1
    fi
    
    # Get number of results
    local total=$(echo "$body" | jq '.total_results')
    
    if [ "$total" -eq 0 ]; then
        log_error "No results found for '$query'"
        return 1
    fi
    
    # Display top 5 results
    echo
    echo "Found $total result(s). Top matches:"
    echo "$body" | jq -r '.results[:5] | to_entries[] | "\(.key + 1). \(.value.title) (\(.value.release_date[:4])) - \(.value.overview[:80])..."'
    echo
    
    # Prompt user to select
    local selection=0
    while true; do
        read -p "Select movie number (1-5) or 0 to cancel: " selection
        
        if [[ "$selection" =~ ^[0-5]$ ]]; then
            break
        else
            log_warn "Invalid selection. Please enter a number between 0 and 5."
        fi
    done
    
    if [ "$selection" -eq 0 ]; then
        log_warn "Cancelled by user"
        return 1
    fi
    
    # Get selected movie details
    local movie=$(echo "$body" | jq -r ".results[$((selection-1))]")
    MOVIE_TITLE_ORIGINAL="$query"  # Use original search query
    MOVIE_TITLE=$(echo "$movie" | jq -r '.title')  # Keep TMDb title for reference
    MOVIE_YEAR=$(echo "$movie" | jq -r '.release_date[:4]')
    TMDB_ID=$(echo "$movie" | jq -r '.id')
    
    # Validate year
    if [ "$MOVIE_YEAR" = "null" ] || [ -z "$MOVIE_YEAR" ]; then
        log_warn "No release year found, using 'Unknown'"
        MOVIE_YEAR="Unknown"
    fi
    
    # Get IMDb ID with retry
    local details_url="https://api.themoviedb.org/3/movie/$TMDB_ID?api_key=$TMDB_API_KEY"
    attempt=1
    
    while [ $attempt -le $MAX_RETRIES ]; do
        local details=$(curl -s "$details_url")
        IMDB_ID=$(echo "$details" | jq -r '.imdb_id')
        
        if [ -n "$IMDB_ID" ] && [ "$IMDB_ID" != "null" ]; then
            break
        fi
        
        log_warn "Failed to get IMDb ID. Retry $attempt/$MAX_RETRIES..."
        sleep $RETRY_DELAY
        ((attempt++))
    done
    
    if [ -z "$IMDB_ID" ] || [ "$IMDB_ID" = "null" ]; then
        log_warn "No IMDb ID found for this movie. Using TMDb ID instead."
        IMDB_ID="imdb-tmdb-$TMDB_ID"
    else
        # Add imdb- prefix if not already there
        if [[ ! "$IMDB_ID" =~ ^imdb- ]]; then
            IMDB_ID="imdb-$IMDB_ID"
        fi
    fi
    
    log_info "Selected: $MOVIE_TITLE_ORIGINAL ($MOVIE_YEAR) [TMDb: $MOVIE_TITLE] - IMDb: $IMDB_ID"
    return 0
}

# Scan disc with makemkvcon
scan_dvd_makemkv() {
    log_info "Scanning disc with MakeMKV (60 second timeout per attempt)..."

    # Try to find disc (makemkvcon uses disc:0, disc:1, disc:2)
    local disc_found=false
    local disc_id=""
    local disc_info=""

    for i in {0..2}; do
        log_debug "Trying MakeMKV disc:$i..."

        local scan_output
        if scan_output=$(timeout 60 makemkvcon -r info disc:$i 2>&1); then
            local exit_code=$?

            if [ $exit_code -eq 0 ] && echo "$scan_output" | grep -q "Title #"; then
                disc_found=true
                disc_id="disc:$i"
                disc_info="$scan_output"
                log_info "Found disc at disc:$i"
                break
            fi
        else
            local exit_code=$?
            if [ $exit_code -eq 124 ]; then
                log_debug "MakeMKV timed out on disc:$i (60s)"
            elif [ $exit_code -eq 137 ]; then
                log_debug "MakeMKV killed on disc:$i"
            else
                log_debug "No disc found at disc:$i (exit code: $exit_code)"
            fi
        fi
    done

    if [ "$disc_found" = false ]; then
        log_error "MakeMKV could not detect disc (tried disc:0-2, 60s timeout each)"
        return 1
    fi

    # Parse titles and find longest
    local longest_title=0
    local longest_duration=0

    while read -r line; do
        # Look for lines like: TINFO:0,9,0,"1:31:31"
        if [[ "$line" =~ TINFO:([0-9]+),9,0,\"([0-9]{1,2}):([0-9]{2}):([0-9]{2})\" ]]; then
            local title_id="${BASH_REMATCH[1]}"
            local hours="${BASH_REMATCH[2]}"
            local minutes="${BASH_REMATCH[3]}"
            local seconds="${BASH_REMATCH[4]}"
            local total_seconds=$((10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))

            log_debug "Title $title_id: $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"

            if [ "$total_seconds" -gt "$longest_duration" ]; then
                longest_duration=$total_seconds
                longest_title=$title_id
            fi
        fi
    done <<< "$disc_info"

    MAIN_TITLE=$longest_title
    MAKEMKV_DISC_ID="$disc_id"

    log_info "Main feature detected: Title $MAIN_TITLE (duration: $(printf "%02d:%02d:%02d" $((longest_duration/3600)) $(((longest_duration%3600)/60)) $((longest_duration%60))))"
    return 0
}

# Scan disc and find main title
scan_dvd() {
    log_info "Scanning disc to find main feature..."

    # Unmount if mounted
    if mount | grep -q "$DISC_DEVICE"; then
        sudo umount "$DISC_DEVICE" 2>/dev/null || log_warn "Could not unmount $DISC_DEVICE"
    fi

    # Scan disc and get all titles
    local scan_output=$(HandBrakeCLI -i "$DISC_DEVICE" --title 0 --scan 2>&1)

    # Extract title information
    log_debug "Analyzing disc structure..."
    
    # Find the longest title (main feature)
    local longest_title=1
    local longest_duration=0
    
    while read -r line; do
        if [[ "$line" =~ \+\ title\ ([0-9]+): ]]; then
            local title_num="${BASH_REMATCH[1]}"
        fi
        
        if [[ "$line" =~ duration:\ ([0-9]{2}):([0-9]{2}):([0-9]{2}) ]]; then
            local hours="${BASH_REMATCH[1]}"
            local minutes="${BASH_REMATCH[2]}"
            local seconds="${BASH_REMATCH[3]}"
            local total_seconds=$((10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))
            
            if [ "$total_seconds" -gt "$longest_duration" ]; then
                longest_duration=$total_seconds
                longest_title=$title_num
            fi
            
            log_debug "Title $title_num: $(printf "%02d:%02d:%02d" $hours $minutes $seconds)"
        fi
    done <<< "$scan_output"
    
    MAIN_TITLE=$longest_title
    log_info "Main feature detected: Title $MAIN_TITLE (duration: $(printf "%02d:%02d:%02d" $((longest_duration/3600)) $(((longest_duration%3600)/60)) $((longest_duration%60))))"
    
    return 0
}

# Extract and convert subtitles
process_subtitles() {
    local mkv_file="$1"
    local base_name="$2"
    local subtitle_count=0

    log_info "Processing subtitles from: $(basename "$mkv_file")"

    # Get subtitle track info
    local track_info
    if ! track_info=$(mkvmerge -J "$mkv_file" 2>&1); then
        log_error "Failed to read MKV file info"
        return 1
    fi

    local sub_tracks=$(echo "$track_info" | jq -r '.tracks[] | select(.type=="subtitles") | "\(.id):\(.properties.language // "und"):\(.codec)"')

    if [ -z "$sub_tracks" ]; then
        log_warn "No subtitle tracks found in this file"
        return 0
    fi

    # Process each subtitle track
    while IFS=: read -r track_id lang codec; do
        log_info "Processing subtitle track $track_id (Language: $lang, Codec: $codec)"

        # Get language code for filename
        local lang_code="${LANG_CODES[$lang]:-$lang}"
        local safe_base_name=$(sanitize_filename "$base_name")
        local output_file="$OUTPUT_DIR/${safe_base_name}.${lang_code}.srt"

        # Process based on codec type
        if [[ "$codec" == *"VobSub"* ]]; then
            # VobSub (DVD) - Extract IDX/SUB and convert with OCR
            log_info "Processing VobSub subtitle (DVD format)"

            # Extract subtitle
            if ! mkvextract tracks "$mkv_file" "$track_id:$TEMP_DIR/sub_${track_id}.idx" 2>&1 | tee -a "$LOG_FILE"; then
                log_warn "Failed to extract subtitle track $track_id"
                continue
            fi

            # Check if extraction was successful
            if [ ! -f "$TEMP_DIR/sub_${track_id}.idx" ] || [ ! -f "$TEMP_DIR/sub_${track_id}.sub" ]; then
                log_warn "Extraction incomplete for track $track_id (missing .idx or .sub file)"
                continue
            fi

            # Convert to SRT using subtile-ocr
            log_info "Converting VobSub to SRT with OCR..."

            # Map language code to tesseract language
            local tess_lang="$lang"

            # Check if tesseract language is installed
            if ! tesseract --list-langs 2>/dev/null | grep -q "^${tess_lang}$"; then
                log_warn "Tesseract language '$tess_lang' not installed, falling back to English"
                tess_lang="eng"
            fi

            log_debug "Using tesseract language: $tess_lang"

            # Use subtile-ocr with system tesseract
            if subtile-ocr -l "$tess_lang" -o "$output_file" "$TEMP_DIR/sub_${track_id}.idx" 2>&1 | tee -a "$LOG_FILE"; then
                log_info "Saved: ${safe_base_name}.${lang_code}.srt"
                ((subtitle_count++))
            else
                log_warn "subtile-ocr conversion failed for track $track_id"
            fi

            # Clean up temporary files
            rm -f "$TEMP_DIR/sub_${track_id}".*

        elif [[ "$codec" == *"HDMV PGS"* ]] || [[ "$codec" == *"PGS"* ]]; then
            # PGS (Blu-ray) - Extract SUP and convert with OCR
            log_info "Processing PGS subtitle (Blu-ray format)"

            # Extract PGS as SUP file
            if ! mkvextract tracks "$mkv_file" "$track_id:$TEMP_DIR/sub_${track_id}.sup" 2>&1 | tee -a "$LOG_FILE"; then
                log_warn "Failed to extract PGS subtitle track $track_id"
                continue
            fi

            if [ ! -f "$TEMP_DIR/sub_${track_id}.sup" ]; then
                log_warn "Extraction incomplete for track $track_id (missing .sup file)"
                continue
            fi

            # Convert PGS to SRT using subtile-ocr
            log_info "Converting PGS to SRT with OCR..."

            # Map language code to tesseract language
            local tess_lang="$lang"

            # Check if tesseract language is installed
            if ! tesseract --list-langs 2>/dev/null | grep -q "^${tess_lang}$"; then
                log_warn "Tesseract language '$tess_lang' not installed, falling back to English"
                tess_lang="eng"
            fi

            log_debug "Using tesseract language: $tess_lang"

            # Use subtile-ocr with PGS/SUP support
            if subtile-ocr -l "$tess_lang" -o "$output_file" "$TEMP_DIR/sub_${track_id}.sup" 2>&1 | tee -a "$LOG_FILE"; then
                log_info "Saved: ${safe_base_name}.${lang_code}.srt"
                ((subtitle_count++))
            else
                log_warn "subtile-ocr conversion failed for PGS track $track_id"
            fi

            # Clean up temporary files
            rm -f "$TEMP_DIR/sub_${track_id}.sup"

        elif [[ "$codec" == *"SubRip/SRT"* ]] || [[ "$codec" == *"SRT"* ]]; then
            # SRT - Direct copy (already text format)
            log_info "Processing SRT subtitle (text format)"

            if ! mkvextract tracks "$mkv_file" "$track_id:$output_file" 2>&1 | tee -a "$LOG_FILE"; then
                log_warn "Failed to extract SRT subtitle track $track_id"
                continue
            fi

            if [ -f "$output_file" ]; then
                log_info "Saved: ${safe_base_name}.${lang_code}.srt"
                ((subtitle_count++))
            else
                log_warn "Extraction incomplete for SRT track $track_id"
            fi

        elif [[ "$codec" == *"SubStationAlpha"* ]] || [[ "$codec" == *"SSA"* ]] || [[ "$codec" == *"ASS"* ]]; then
            # ASS/SSA - Extract as-is (text format with styling)
            log_info "Processing ASS/SSA subtitle (text format)"

            local ass_output="$OUTPUT_DIR/${safe_base_name}.${lang_code}.ass"

            if ! mkvextract tracks "$mkv_file" "$track_id:$ass_output" 2>&1 | tee -a "$LOG_FILE"; then
                log_warn "Failed to extract ASS/SSA subtitle track $track_id"
                continue
            fi

            if [ -f "$ass_output" ]; then
                log_info "Saved: ${safe_base_name}.${lang_code}.ass"
                ((subtitle_count++))
            else
                log_warn "Extraction incomplete for ASS/SSA track $track_id"
            fi

        else
            log_warn "Unsupported subtitle codec for track $track_id: $codec"
            log_warn "Supported formats: VobSub (DVD), PGS (Blu-ray), SRT, ASS/SSA"
            continue
        fi

    done <<< "$sub_tracks"

    log_info "Processed $subtitle_count subtitle track(s) successfully"
    return 0
}

# Operation state tracking
update_operation_state() {
    local operation="$1"
    local file_path="$2"
    local progress="${3:-0}"

    echo "${operation}|$(date +%s)|${file_path}|${progress}" > "$STATE_FILE"
}

clear_operation_state() {
    rm -f "$STATE_FILE"
}

# Detect interrupted operations
detect_interrupted_operation() {
    if [ ! -f "$STATE_FILE" ]; then
        return 1
    fi

    local state_age=$(($(date +%s) - $(stat -c%Y "$STATE_FILE" 2>/dev/null || stat -f%m "$STATE_FILE" 2>/dev/null)))

    # Consider operation interrupted if state file is older than 5 minutes
    if [ "$state_age" -gt 300 ]; then
        IFS='|' read -r operation timestamp file_path progress < "$STATE_FILE"

        log_warn "⚠️  Detected interrupted operation from $(date -d @"$timestamp" 2>/dev/null || date -r "$timestamp" 2>/dev/null)"
        log_warn "Operation: $operation"
        log_warn "File: $file_path"
        log_warn "Progress: ${progress}%"
        echo
        log_info "Use Mode 4 (Recovery mode) to clean up and resume"
        echo

        return 0
    fi

    return 1
}

# Detect incomplete backup files (< 100MB)
detect_incomplete_backups() {
    local incomplete_files=()

    if [ ! -d "$BACKUP_DIR" ]; then
        return 0
    fi

    while IFS= read -r file; do
        if [ -f "$file" ]; then
            local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
            if [ "$size" -lt 104857600 ]; then  # 100MB
                incomplete_files+=("$file")
            fi
        fi
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.mkv" -type f)

    if [ ${#incomplete_files[@]} -gt 0 ]; then
        log_warn "Found ${#incomplete_files[@]} incomplete backup file(s):"
        for file in "${incomplete_files[@]}"; do
            local size_mb=$(($(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null) / 1048576))
            log_warn "  - $(basename "$file") (${size_mb}MB - likely incomplete)"
        done
        return 0
    fi

    return 1
}

# Cleanup incomplete backup files
cleanup_incomplete_backups() {
    if [ ! -d "$BACKUP_DIR" ]; then
        return 0
    fi

    local deleted_count=0

    while IFS= read -r file; do
        if [ -f "$file" ]; then
            local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
            if [ "$size" -lt 104857600 ]; then  # 100MB
                log_info "Deleting incomplete backup: $(basename "$file")"
                rm -f "$file"
                ((deleted_count++))
            fi
        fi
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.mkv" -type f)

    if [ "$deleted_count" -gt 0 ]; then
        log_info "Deleted $deleted_count incomplete backup file(s)"
    fi
}

# Detect orphaned backups not in queue
detect_orphaned_backups() {
    if [ ! -d "$BACKUP_DIR" ]; then
        return 1
    fi

    local orphaned_files=()

    while IFS= read -r file; do
        if [ -f "$file" ]; then
            local basename_file=$(basename "$file")

            # Check if this backup is in the queue
            if [ -f "$QUEUE_FILE" ]; then
                if ! grep -q "^${file}|" "$QUEUE_FILE"; then
                    # Check file size (skip incomplete files)
                    local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
                    if [ "$size" -ge 104857600 ]; then  # >= 100MB
                        orphaned_files+=("$file")
                    fi
                fi
            else
                # No queue file exists, all backups are orphaned
                local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
                if [ "$size" -ge 104857600 ]; then
                    orphaned_files+=("$file")
                fi
            fi
        fi
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name "*.mkv" -type f)

    if [ ${#orphaned_files[@]} -gt 0 ]; then
        echo "${orphaned_files[@]}"
        return 0
    fi

    return 1
}

# Recover orphaned backups to queue
recover_orphaned_backups() {
    local orphaned_files
    if ! orphaned_files=($(detect_orphaned_backups)); then
        log_info "No orphaned backups found"
        return 0
    fi

    log_info "Found ${#orphaned_files[@]} orphaned backup(s) not in queue"
    echo

    for file in "${orphaned_files[@]}"; do
        local basename_file=$(basename "$file" .mkv)
        local imdb_id=""

        # Try to extract IMDb ID from filename (format: {imdb-...}_raw)
        if [[ "$basename_file" =~ imdb-([^_]+)_raw$ ]]; then
            imdb_id="imdb-${BASH_REMATCH[1]}"
        fi

        log_info "Orphaned backup: $(basename "$file")"
        if [ -n "$imdb_id" ]; then
            log_info "Detected IMDb ID: $imdb_id"
        fi

        echo
        read -p "Enter movie title for this backup: " movie_title

        if [ -z "$movie_title" ]; then
            log_warn "Skipping this backup (no title entered)"
            continue
        fi

        read -p "Enter year: " year

        if [ -z "$year" ]; then
            log_warn "Skipping this backup (no year entered)"
            continue
        fi

        if [ -z "$imdb_id" ]; then
            read -p "Enter IMDb ID (e.g., imdb-tt1234567): " imdb_id
            if [ -z "$imdb_id" ]; then
                log_warn "Skipping this backup (no IMDb ID entered)"
                continue
            fi
        fi

        # Add to queue
        add_to_queue "$file" "$movie_title" "$year" "$imdb_id"
        log_info "Added to queue: $movie_title ($year)"
        echo
    done

    log_info "Orphaned backup recovery complete"
}

# Cleanup partial encoded files
cleanup_partial_files() {
    local deleted_count=0

    # Clean partial encoded files in TEMP_DIR
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
            if [ "$size" -lt 52428800 ]; then  # < 50MB
                log_info "Deleting partial encoded file: $(basename "$file")"
                rm -f "$file"
                ((deleted_count++))
            fi
        fi
    done < <(find "$TEMP_DIR" -maxdepth 1 -name "encoded_*.mkv" -type f 2>/dev/null)

    if [ "$deleted_count" -gt 0 ]; then
        log_info "Deleted $deleted_count partial encoded file(s)"
    fi
}

# Backup disc with MakeMKV (lossless only)
backup_dvd() {
    local output_file="$1"

    # Check disk space
    if ! check_disk_space "$(dirname "$output_file")" 10; then
        return 1
    fi

    # Track operation state
    update_operation_state "backup" "$output_file" 0

    # MakeMKV is required for backup
    if [ "$MAKEMKV_AVAILABLE" != true ]; then
        log_error "MakeMKV is required for disc backup but is not available"
        log_error "Please install MakeMKV"
        clear_operation_state
        return 1
    fi

    log_info "Backing up disc with MakeMKV (lossless, 30 minute timeout)..."

    # MakeMKV outputs to a directory, then we need to find the file
    local temp_output_dir="$TEMP_DIR/makemkv_tmp"
    mkdir -p "$temp_output_dir"

    # Run makemkvcon with 30-minute timeout and progress display
    if timeout 1800 makemkvcon -r --progress=-same mkv "$MAKEMKV_DISC_ID" "$MAIN_TITLE" "$temp_output_dir" 2>&1 | \
        tee -a "$LOG_FILE" | \
        grep --line-buffered -E "^PRGV:|^PRGT:|^MSG:" | \
        while IFS= read -r line; do
            if [[ "$line" =~ ^PRGV:([0-9]+),([0-9]+),([0-9]+) ]]; then
                local current="${BASH_REMATCH[1]}"
                local total="${BASH_REMATCH[2]}"
                local max="${BASH_REMATCH[3]}"
                if [ "$max" -gt 0 ]; then
                    local percent=$((current * 100 / max))
                    printf "\r[MakeMKV] Progress: %3d%% " "$percent"
                fi
            elif [[ "$line" =~ ^PRGT:([0-9]+),([0-9]+),([0-9]+) ]]; then
                local current="${BASH_REMATCH[1]}"
                local total="${BASH_REMATCH[2]}"
                local max="${BASH_REMATCH[3]}"
                if [ "$max" -gt 0 ]; then
                    local percent=$((current * 100 / max))
                    printf "\r[MakeMKV] Total: %3d%% " "$percent"
                fi
            elif [[ "$line" =~ MSG:3031 ]]; then
                # Copy complete message
                echo ""
                log_info "Copy complete"
            fi
        done; then
        local makemkv_exit_code=${PIPESTATUS[0]}

        if [ $makemkv_exit_code -eq 124 ]; then
            log_error "MakeMKV backup timed out after 30 minutes"
            rm -rf "$temp_output_dir"
            clear_operation_state
            return 1
        elif [ $makemkv_exit_code -ne 0 ]; then
            log_error "MakeMKV failed with exit code $makemkv_exit_code"
            rm -rf "$temp_output_dir"
            clear_operation_state
            return 1
        else
            # Success - find the created MKV file
            local created_file=$(find "$temp_output_dir" -name "*.mkv" -type f | head -1)

            if [ -n "$created_file" ] && [ -f "$created_file" ]; then
                # Move to final location
                mv "$created_file" "$output_file"

                # Clean up temp directory
                rm -rf "$temp_output_dir"

                # Verify output file
                local output_size=$(stat -c%s "$output_file" 2>/dev/null || stat -f%z "$output_file" 2>/dev/null)
                if [ "$output_size" -lt 1000000 ]; then
                    log_error "Output file is suspiciously small (< 1MB). Backup may have failed."
                    clear_operation_state
                    return 1
                fi

                log_info "MakeMKV backup complete (lossless)"
                clear_operation_state
                return 0
            else
                log_error "MakeMKV did not create output file"
                rm -rf "$temp_output_dir"
                clear_operation_state
                return 1
            fi
        fi
    else
        log_error "MakeMKV command failed"
        rm -rf "$temp_output_dir"
        clear_operation_state
        return 1
    fi
}

# Encode with DVD to x264 MKV preset
encode_with_custom_preset() {
    local input_file="$1"
    local output_file="$2"

    if [ ! -f "$PRESET_DVD" ]; then
        log_error "DVD preset file not found: $PRESET_DVD"
        return 1
    fi

    log_info "Encoding with preset: DVD to x264 MKV"
    log_info "Settings: x264 veryslow, film tune, quality 20, multi-pass"
    log_info "Using preset file: $(basename "$PRESET_DVD")"

    HandBrakeCLI \
        --preset-import-file "$PRESET_DVD" \
        --preset "DVD to x264 MKV" \
        -i "$input_file" \
        -o "$output_file" \
        2>&1 | tee -a "$LOG_FILE" | \
        while IFS= read -r line; do
            # Show progress lines with percentage
            if [[ "$line" =~ Encoding:.*task.*[0-9]+\.[0-9]+\ % ]]; then
                printf "\r%s" "$line"
            # Show important status messages
            elif [[ "$line" =~ (Starting\ Task|average\ encoding\ speed|sync:\ got) ]]; then
                echo ""
                echo "$line"
            fi
        done

    local hb_exit_code=${PIPESTATUS[0]}
    echo ""  # Newline after progress
    return $hb_exit_code
}

# Encode with BluRay 1080p x264 preset
encode_with_bluray_1080p_x264() {
    local input_file="$1"
    local output_file="$2"

    if [ ! -f "$PRESET_BLURAY_1080P" ]; then
        log_error "BluRay 1080p preset file not found: $PRESET_BLURAY_1080P"
        return 1
    fi

    log_info "Encoding with preset: BluRay to x264 MKV"
    log_info "Settings: x264 veryslow, film tune, quality 24, multi-pass"
    log_info "Using preset file: $(basename "$PRESET_BLURAY_1080P")"

    HandBrakeCLI \
        --preset-import-file "$PRESET_BLURAY_1080P" \
        --preset "BluRay to x264 MKV" \
        -i "$input_file" \
        -o "$output_file" \
        2>&1 | tee -a "$LOG_FILE" | \
        while IFS= read -r line; do
            # Show progress lines with percentage
            if [[ "$line" =~ Encoding:.*task.*[0-9]+\.[0-9]+\ % ]]; then
                printf "\r%s" "$line"
            # Show important status messages
            elif [[ "$line" =~ (Starting\ Task|average\ encoding\ speed|sync:\ got) ]]; then
                echo ""
                echo "$line"
            fi
        done

    local hb_exit_code=${PIPESTATUS[0]}
    echo ""  # Newline after progress
    return $hb_exit_code
}

# Encode with BluRay 4K x265 preset
encode_with_bluray_4k_x265() {
    local input_file="$1"
    local output_file="$2"

    if [ ! -f "$PRESET_BLURAY_4K" ]; then
        log_error "BluRay 4K preset file not found: $PRESET_BLURAY_4K"
        return 1
    fi

    log_info "Encoding with preset: BluRay 4K to x265 MKV"
    log_info "Settings: x265 10-bit slow, quality 24, multi-pass"
    log_info "Using preset file: $(basename "$PRESET_BLURAY_4K")"

    HandBrakeCLI \
        --preset-import-file "$PRESET_BLURAY_4K" \
        --preset "BluRay 4K to x265 MKV" \
        -i "$input_file" \
        -o "$output_file" \
        2>&1 | tee -a "$LOG_FILE" | \
        while IFS= read -r line; do
            # Show progress lines with percentage
            if [[ "$line" =~ Encoding:.*task.*[0-9]+\.[0-9]+\ % ]]; then
                printf "\r%s" "$line"
            # Show important status messages
            elif [[ "$line" =~ (Starting\ Task|average\ encoding\ speed|sync:\ got) ]]; then
                echo ""
                echo "$line"
            fi
        done

    local hb_exit_code=${PIPESTATUS[0]}
    echo ""  # Newline after progress
    return $hb_exit_code
}

# Add to transcode queue
add_to_queue() {
    local backup_file="$1"
    local movie_title="$2"
    local year="$3"
    local imdb_id="$4"
    local preset="$5"

    echo "${backup_file}|${movie_title}|${year}|${imdb_id}|${preset}" >> "$QUEUE_FILE"
    log_info "Added to transcode queue: $movie_title ($year) [Preset: $preset]"
}

# Process transcode queue (resumable)
process_transcode_queue() {
    if [ ! -f "$QUEUE_FILE" ] || [ ! -s "$QUEUE_FILE" ]; then
        log_error "Transcode queue is empty"
        return 1
    fi

    local total_items=$(wc -l < "$QUEUE_FILE")
    local current_item=0

    log_info "=== Processing Transcode Queue ==="
    log_info "Total items in queue: $total_items"
    echo

    # Process queue line by line, removing completed items as we go
    local processed_items=0
    while [ -f "$QUEUE_FILE" ] && [ -s "$QUEUE_FILE" ]; do
        # Break if we've processed all items (prevent infinite loop with --keep-temp)
        if [ "$KEEP_TEMP" = true ] && [ "$processed_items" -ge "$total_items" ]; then
            break
        fi

        # Read line from queue (with backward compatibility for old format)
        # When --keep-temp is enabled, read line N+1 instead of always reading line 1
        if [ "$KEEP_TEMP" = true ]; then
            # Read specific line number (processed_items + 1)
            IFS='|' read -r backup_file movie_title year imdb_id preset < <(sed -n "$((processed_items + 1))p" "$QUEUE_FILE")
        else
            # Normal mode: always read first line (it gets deleted after processing)
            IFS='|' read -r backup_file movie_title year imdb_id preset < "$QUEUE_FILE"
        fi

        # Backward compatibility: if no preset field, use default
        if [ -z "$preset" ]; then
            preset="custom_x264_mkv2"
            log_warn "No preset specified in queue, using default: custom_x264_mkv2"
        fi

        ((current_item++))

        log_info "=== Processing $current_item/$total_items ==="
        log_info "Movie: $movie_title ($year)"
        log_info "IMDb ID: $imdb_id"
        log_info "Preset: $preset"

        # Check if backup file exists
        if [ ! -f "$backup_file" ]; then
            log_error "Backup file not found: $backup_file"
            log_warn "Skipping this item. The backup may have been deleted or moved."

            # Log as failed
            echo "$(date +%s)|${movie_title}|${year}|${imdb_id}|FAILED_MISSING_BACKUP" >> "$COMPLETED_LOG"

            # Remove this line from queue
            sed -i '1d' "$QUEUE_FILE" 2>/dev/null || sed -i '' '1d' "$QUEUE_FILE" 2>/dev/null
            echo
            continue
        fi

        # Create filename base
        local safe_title=$(sanitize_filename "$movie_title")
        local filename_base="${safe_title} (${year}) {${imdb_id}}"

        # Extract subtitles from backup BEFORE encoding (backup has all subtitle tracks)
        update_operation_state "subtitles" "$backup_file" 0
        log_info "Extracting subtitles from backup file..."
        if ! process_subtitles "$backup_file" "$filename_base"; then
            log_warn "Subtitle extraction had errors, but continuing with encoding"
        fi

        # Encode from backup
        local encoded_output="$TEMP_DIR/encoded_${current_item}.mkv"

        # Track operation state
        update_operation_state "transcode" "$backup_file" 0

        local encode_success=false

        # Encode based on preset
        case "$preset" in
            custom_x264_mkv2)
                if encode_with_custom_preset "$backup_file" "$encoded_output"; then
                    if [ -f "$encoded_output" ]; then
                        log_info "Encoding complete"
                        encode_success=true
                    fi
                fi
                ;;
            bluray_1080p_x264)
                if encode_with_bluray_1080p_x264 "$backup_file" "$encoded_output"; then
                    if [ -f "$encoded_output" ]; then
                        log_info "Encoding complete"
                        encode_success=true
                    fi
                fi
                ;;
            bluray_4k_x265)
                if encode_with_bluray_4k_x265 "$backup_file" "$encoded_output"; then
                    if [ -f "$encoded_output" ]; then
                        log_info "Encoding complete"
                        encode_success=true
                    fi
                fi
                ;;
            *)
                log_error "Unknown preset: $preset"
                log_warn "Skipping this item"

                # Log as failed
                echo "$(date +%s)|${movie_title}|${year}|${imdb_id}|FAILED_UNKNOWN_PRESET" >> "$COMPLETED_LOG"

                # Remove this line from queue
                sed -i '1d' "$QUEUE_FILE" 2>/dev/null || sed -i '' '1d' "$QUEUE_FILE" 2>/dev/null
                echo
                continue
                ;;
        esac

        # If encoding succeeded, move files
        if [ "$encode_success" = true ]; then
            # Move encoded file to output with final name
            local final_output="$OUTPUT_DIR/${filename_base}.mkv"
            mv "$encoded_output" "$final_output"
            log_info "Saved: ${filename_base}.mkv"

            # Move to NAS
            if ! move_to_nas "$OUTPUT_DIR" "$NAS_MOVIES" "$filename_base"; then
                log_warn "Files could not be moved to NAS for this item"
                log_info "Files remain in: $OUTPUT_DIR"
            fi

            # Remove backup file after successful processing (unless --keep-temp)
            if [ "$KEEP_TEMP" = true ]; then
                log_info "Preserving backup file (--keep-temp): $(basename "$backup_file")"
            else
                rm -f "$backup_file"
                log_info "Removed backup file: $(basename "$backup_file")"
            fi

            # Log as completed
            echo "$(date +%s)|${movie_title}|${year}|${imdb_id}|SUCCESS" >> "$COMPLETED_LOG"

            # Clear operation state
            clear_operation_state
        else
            log_error "Encoding failed for: $movie_title"
            log_info "Backup preserved at: $backup_file"

            # Log as failed
            echo "$(date +%s)|${movie_title}|${year}|${imdb_id}|FAILED_ENCODING" >> "$COMPLETED_LOG"
        fi

        # Remove this item from queue (whether success or failure) unless --keep-temp
        if [ "$KEEP_TEMP" = true ]; then
            log_debug "Preserving queue entry (--keep-temp)"
            ((processed_items++))
            # Don't remove from queue, just track that we processed it
        else
            sed -i '1d' "$QUEUE_FILE" 2>/dev/null || sed -i '' '1d' "$QUEUE_FILE" 2>/dev/null
        fi

        echo
    done

    # If queue is now empty, remove it (unless --keep-temp)
    if [ "$KEEP_TEMP" = false ]; then
        if [ -f "$QUEUE_FILE" ] && [ ! -s "$QUEUE_FILE" ]; then
            rm -f "$QUEUE_FILE"
        fi
    else
        log_info "Queue file preserved for re-processing (--keep-temp): $QUEUE_FILE"
    fi

    log_info "=== Queue Processing Complete ==="
    clear_operation_state

    return 0
}

# Display ASCII art banner
show_banner() {
    clear
    echo ""
    echo "██████╗ ██╗███████╗ ██████╗    ██████╗ ██╗██████╗ ██████╗ ██╗███╗   ██╗ ██████╗                                             "
    echo "██╔══██╗██║██╔════╝██╔════╝    ██╔══██╗██║██╔══██╗██╔══██╗██║████╗  ██║██╔════╝                                             "
    echo "██║  ██║██║███████╗██║         ██████╔╝██║██████╔╝██████╔╝██║██╔██╗ ██║██║  ███╗                                            "
    echo "██║  ██║██║╚════██║██║         ██╔══██╗██║██╔═══╝ ██╔═══╝ ██║██║╚██╗██║██║   ██║                                            "
    echo "██████╔╝██║███████║╚██████╗    ██║  ██║██║██║     ██║     ██║██║ ╚████║╚██████╔╝                                            "
    echo "╚═════╝ ╚═╝╚══════╝ ╚═════╝    ╚═╝  ╚═╝╚═╝╚═╝     ╚═╝     ╚═╝╚═╝  ╚═══╝ ╚═════╝                                             "
    echo "                                                                                                                            "
    echo " █████╗ ██╗   ██╗████████╗ ██████╗ ███╗   ███╗ █████╗ ████████╗██╗ ██████╗ ███╗   ██╗    ████████╗ ██████╗  ██████╗ ██╗     "
    echo "██╔══██╗██║   ██║╚══██╔══╝██╔═══██╗████╗ ████║██╔══██╗╚══██╔══╝██║██╔═══██╗████╗  ██║    ╚══██╔══╝██╔═══██╗██╔═══██╗██║     "
    echo "███████║██║   ██║   ██║   ██║   ██║██╔████╔██║███████║   ██║   ██║██║   ██║██╔██╗ ██║       ██║   ██║   ██║██║   ██║██║     "
    echo "██╔══██║██║   ██║   ██║   ██║   ██║██║╚██╔╝██║██╔══██║   ██║   ██║██║   ██║██║╚██╗██║       ██║   ██║   ██║██║   ██║██║     "
    echo "██║  ██║╚██████╔╝   ██║   ╚██████╔╝██║ ╚═╝ ██║██║  ██║   ██║   ██║╚██████╔╝██║ ╚████║       ██║   ╚██████╔╝╚██████╔╝███████╗"
    echo "╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝       ╚═╝    ╚═════╝  ╚═════╝ ╚══════╝"
    echo ""
    echo "This script is provided as-is for personal use and backuping of legally obtained discs."
    echo ""
    sleep 2
}

# Move files to NAS with verification
move_to_nas() {
    local source_dir="$1"
    local dest_dir="$2"
    local movie_folder="$3"
    
    log_info "Moving files to NAS..."
    
    # Check NAS is still mounted
    if ! check_nas_mount; then
        log_error "NAS not available. Files remain in: $source_dir"
        return 1
    fi
    
    # Create movie folder on NAS
    local movie_path="$dest_dir/$movie_folder"
    if ! mkdir -p "$movie_path" 2>&1 | tee -a "$LOG_FILE"; then
        log_error "Failed to create movie folder: $movie_path"
        return 1
    fi
    
    log_info "Created folder: $movie_folder"
    
    # Move files and verify (only files matching the movie folder name)
    local file_count=0
    for file in "$source_dir"/"$movie_folder".*; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            log_info "Moving: $filename"
            
            # Copy first, then verify, then delete original
            if cp "$file" "$movie_path/$filename" 2>&1 | tee -a "$LOG_FILE"; then
                # Verify file sizes match
                local src_size=$(stat -c%s "$file" 2>/dev/null)
                local dst_size=$(stat -c%s "$movie_path/$filename" 2>/dev/null)
                
                if [ "$src_size" -eq "$dst_size" ]; then
                    rm "$file"
                    ((file_count++))
                    log_info "Successfully moved: $filename"
                else
                    log_error "Size mismatch for $filename - keeping original"
                    rm "$movie_path/$filename"
                fi
            else
                log_error "Failed to copy $filename to NAS"
            fi
        fi
    done
    
    log_info "Moved $file_count file(s) to $movie_path"
    return 0
}

# Main workflow
main() {
    # Initialize
    mkdir -p "$WORK_DIR" "$TEMP_DIR" "$BACKUP_DIR" "$OUTPUT_DIR"

    # Show banner
    show_banner

    log_info "Log file: $LOG_FILE"
    echo

    # Pre-flight checks
    check_dependencies

    # Detect interrupted operations and show warning
    detect_interrupted_operation || true

    # Show initial menu first
    echo "Select processing mode:"
    echo "1. Backup Disc to queue (DVD/Blu-ray - lossless copy, no encoding)"
    echo "2. Process transcode queue (encode all queued discs → subtitles → NAS)"
    echo "3. Process subtitles only (requires existing MKV file)"
    echo "4. Recovery mode (resume interrupted session)"
    echo "0. Exit"
    echo

    local mode=0
    while true; do
        read -p "Enter mode (0-4): " mode

        if [[ "$mode" =~ ^[0-4]$ ]]; then
            break
        else
            log_warn "Invalid selection. Please enter a number between 0 and 4."
        fi
    done

    if [ "$mode" -eq 0 ]; then
        log_warn "Exiting"
        exit 0
    fi

    log_info "Selected mode: $mode"
    echo

    # Mode-specific pre-flight checks
    if [ "$mode" -eq 1 ]; then
        # Mode 1 needs disc and TMDb
        if ! check_nas_mount; then
            log_warn "NAS is not mounted. Files will remain in output directory."
            read -p "Continue anyway? (y/n): " continue_without_nas
            if [ "$continue_without_nas" != "y" ]; then
                exit 1
            fi
        fi

        # Check if disc device is present and readable
        if [ ! -b "$DISC_DEVICE" ]; then
            log_error "Disc device not found: $DISC_DEVICE"
            exit 1
        fi

        # Unmount if auto-mounted
        if mount | grep -q "$DISC_DEVICE"; then
            log_info "Unmounting auto-mounted disc..."
            sudo umount "$DISC_DEVICE" 2>/dev/null || true
            log_info "Waiting for drive to be ready..."
            sleep 3
        fi

        # Quick test if disc is readable (with longer timeout)
        log_info "Checking for disc in drive..."
        local scan_test=$(timeout 15 HandBrakeCLI -i "$DISC_DEVICE" --scan 2>&1)
        if ! echo "$scan_test" | grep -q "scan: DVD has"; then
            log_error "No readable disc found in drive. Please insert a disc."
            log_debug "Scan output: $scan_test"
            exit 1
        fi

        # Get movie title from user
        echo
        read -p "Enter movie title to search: " search_query

        if [ -z "$search_query" ]; then
            log_error "No title entered"
            exit 1
        fi

        # Search TMDb and get metadata
        if ! search_tmdb "$search_query"; then
            log_error "Failed to get movie metadata"
            exit 1
        fi

        # Create filename base (using original title)
        local safe_title=$(sanitize_filename "$MOVIE_TITLE_ORIGINAL")
        FILENAME_BASE="${safe_title} (${MOVIE_YEAR}) {${IMDB_ID}}"

        echo
        log_info "Final filename will be: ${FILENAME_BASE}.mkv"
        echo

        # Select encoding preset for this disc
        echo "Select encoding preset for this disc:"
        echo "1. DVD to x264 MKV (SD/DVD content - CRF 20, veryslow, ~60-90min)"
        echo "   - x264 veryslow, film tune, quality 20, multi-pass"
        echo "   - AC3 audio passthrough, subtitle scan (not burned)"
        echo
        echo "2. BluRay to x264 MKV (1080p content - CRF 24, veryslow, ~90-120min)"
        echo "   - x264 veryslow, film tune, quality 24, multi-pass"
        echo "   - AC3 audio encode, subtitle scan (not burned)"
        echo
        echo "3. BluRay 4K to x265 (4K UHD content - CRF 24, slow, ~120-180min)"
        echo "   - x265 10-bit slow, quality 24, multi-pass"
        echo "   - AC3 audio passthrough, subtitle scan (not burned)"
        echo

        local preset_choice=""
        while [[ ! "$preset_choice" =~ ^[1-3]$ ]]; do
            read -p "Enter preset number (1-3, required): " preset_choice
            if [[ ! "$preset_choice" =~ ^[1-3]$ ]]; then
                log_warn "Invalid selection. Please enter 1, 2, or 3"
            fi
        done

        case "$preset_choice" in
            1)
                SELECTED_PRESET="custom_x264_mkv2"
                log_info "Selected preset: DVD to x264 MKV"
                ;;
            2)
                SELECTED_PRESET="bluray_1080p_x264"
                log_info "Selected preset: BluRay to x264 MKV"
                ;;
            3)
                SELECTED_PRESET="bluray_4k_x265"
                log_info "Selected preset: BluRay 4K to x265"
                ;;
        esac
        echo

    elif [ "$mode" -eq 2 ]; then
        # Mode 2 needs NAS but not disc
        if ! check_nas_mount; then
            log_warn "NAS is not mounted. Files will remain in output directory."
            read -p "Continue anyway? (y/n): " continue_without_nas
            if [ "$continue_without_nas" != "y" ]; then
                exit 1
            fi
        fi
    fi

    echo
    log_info "=== Starting Processing ==="

    # Mode 4: Recovery mode
    if [ "$mode" -eq 4 ]; then
        log_info "=== Recovery Mode ==="
        echo

        # Detect issues
        local has_issues=false

        # Check for incomplete backups
        if detect_incomplete_backups; then
            has_issues=true
        fi

        # Check for orphaned backups
        local orphaned_count=0
        if detect_orphaned_backups > /dev/null 2>&1; then
            orphaned_files=($(detect_orphaned_backups))
            orphaned_count=${#orphaned_files[@]}
            log_warn "Found $orphaned_count orphaned backup(s) not in queue"
            has_issues=true
        fi

        # Check for partial encoded files
        local partial_count=$(find "$TEMP_DIR" -maxdepth 1 -name "encoded_*.mkv" -type f 2>/dev/null | wc -l)
        if [ "$partial_count" -gt 0 ]; then
            log_warn "Found $partial_count partial encoded file(s)"
            has_issues=true
        fi

        # Check transcode queue
        if [ -f "$QUEUE_FILE" ] && [ -s "$QUEUE_FILE" ]; then
            local queue_count=$(wc -l < "$QUEUE_FILE")
            log_info "Transcode queue has $queue_count item(s) pending"
        fi

        # Check completed log
        if [ -f "$COMPLETED_LOG" ] && [ -s "$COMPLETED_LOG" ]; then
            local completed_count=$(wc -l < "$COMPLETED_LOG")
            log_info "Completed log has $completed_count item(s)"
        fi

        if [ "$has_issues" = false ]; then
            log_info "No recovery issues detected"
            exit 0
        fi

        echo
        echo "Recovery options:"
        echo "1. Clean up incomplete and partial files"
        echo "2. Recover orphaned backups to queue"
        echo "3. Resume transcode queue (skip missing backups)"
        echo "4. Full cleanup (delete all backups and queue)"
        echo "0. Back to main menu"
        echo

        local recovery_choice=0
        while true; do
            read -p "Enter recovery option (0-4): " recovery_choice

            if [[ "$recovery_choice" =~ ^[0-4]$ ]]; then
                break
            else
                log_warn "Invalid selection. Please enter a number between 0 and 4."
            fi
        done

        case $recovery_choice in
            0)
                log_info "Returning to main menu"
                exec "$0" "$@"
                ;;
            1)
                log_info "Cleaning up incomplete and partial files..."
                cleanup_incomplete_backups
                cleanup_partial_files
                clear_operation_state
                log_info "Cleanup complete"
                ;;
            2)
                log_info "Recovering orphaned backups..."
                recover_orphaned_backups
                log_info "Recovery complete. You can now use Mode 2 to transcode the queue."
                ;;
            3)
                log_info "Resuming transcode queue..."
                # Check NAS mount
                if ! check_nas_mount; then
                    log_warn "NAS is not mounted. Files will remain in output directory."
                    read -p "Continue anyway? (y/n): " continue_without_nas
                    if [ "$continue_without_nas" != "y" ]; then
                        exit 1
                    fi
                fi
                if ! process_transcode_queue; then
                    log_error "Queue processing failed"
                    cleanup
                    exit 1
                fi
                cleanup
                log_info "=== Queue Processing Complete ==="
                ;;
            4)
                log_warn "WARNING: This will delete ALL backups and queue files!"
                read -p "Are you sure? (yes/no): " confirm
                if [ "$confirm" = "yes" ]; then
                    log_info "Performing full cleanup..."
                    rm -rf "$BACKUP_DIR"/*
                    rm -f "$QUEUE_FILE"
                    rm -f "$STATE_FILE"
                    cleanup_partial_files
                    log_info "Full cleanup complete"
                else
                    log_info "Full cleanup cancelled"
                fi
                ;;
        esac

        exit 0
    fi

    # Mode 3: Process subtitles only - no disc needed
    if [ "$mode" -eq 3 ]; then
        log_info "Mode 3: Processing subtitles from existing MKV file (no disc required)"
        log_info "Looking for existing MKV file..."

        # Search for MKV files in backups, temp, and output directories
        local found_files=$(find "$BACKUP_DIR" "$TEMP_DIR" "$OUTPUT_DIR" -maxdepth 1 -name "*.mkv" -type f 2>/dev/null)

        if [ -z "$found_files" ]; then
            log_error "No MKV files found in: $BACKUP_DIR, $TEMP_DIR, or $OUTPUT_DIR"
            log_error "Please backup a disc or transcode the queue first"
            exit 1
        fi
        
        # Show available files
        echo
        echo "Available MKV files:"
        local file_num=1
        declare -a file_array
        while IFS= read -r file; do
            echo "$file_num. $(basename "$file") [$(dirname "$file")]"
            file_array[$file_num]="$file"
            ((file_num++))
        done <<< "$found_files"
        echo "0. Cancel"
        echo
        
        local selection=0
        while true; do
            read -p "Select file to process (0-$((file_num-1))): " selection
            
            if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 0 ] && [ "$selection" -lt "$file_num" ]; then
                break
            else
                log_warn "Invalid selection. Please try again."
            fi
        done
        
        if [ "$selection" -eq 0 ]; then
            log_warn "Cancelled by user"
            exit 0
        fi
        
        TEMP_OUTPUT="${file_array[$selection]}"
        log_info "Selected file: $(basename "$TEMP_OUTPUT")"
        
        # Extract the base name from the selected file (without .mkv extension)
        FILENAME_BASE=$(basename "$TEMP_OUTPUT" .mkv)
        
        # Process subtitles from the MKV
        if ! process_subtitles "$TEMP_OUTPUT" "$FILENAME_BASE"; then
            log_warn "Subtitle processing had errors"
            log_info "MKV file preserved at: $TEMP_OUTPUT"
        fi
        
        log_info "=== Subtitle Processing Complete ==="
        log_info "Subtitle files saved to: $OUTPUT_DIR"
        cleanup
        exit 0
    fi
    
    # Mode 1: Backup Disc to queue
    if [ "$mode" -eq 1 ]; then
        # Clean up any incomplete backups before starting
        log_info "Checking for incomplete backups..."
        cleanup_incomplete_backups

        # Check if MakeMKV is available (required)
        if [ "$MAKEMKV_AVAILABLE" != true ]; then
            log_error "MakeMKV is required for backup mode but is not available"
            log_error "Please install MakeMKV (see README.md)"
            cleanup
            exit 1
        fi

        while true; do
            # Scan disc to find main title using MakeMKV
            if ! scan_dvd_makemkv; then
                log_error "MakeMKV scan failed"
                cleanup
                exit 1
            fi

            # Create backup filename
            local backup_file="$BACKUP_DIR/${IMDB_ID}_raw.mkv"

            # Backup disc (uses MakeMKV)
            if ! backup_dvd "$backup_file"; then
                log_error "Disc backup failed"
                cleanup
                exit 1
            fi

            log_info "Backup file size: $(du -h "$backup_file" | cut -f1)"

            # Add to transcode queue
            add_to_queue "$backup_file" "$MOVIE_TITLE_ORIGINAL" "$MOVIE_YEAR" "$IMDB_ID" "$SELECTED_PRESET"

            echo
            log_info "=== Disc Backup Complete ==="
            log_info "Backup saved: $(basename "$backup_file")"
            echo

            # Show sub-menu
            echo "What would you like to do next?"
            echo "1. Backup another disc"
            echo "2. Start transcoding queue now"
            echo "0. Exit"
            echo

            local next_action=0
            while true; do
                read -p "Enter choice (0-2): " next_action

                if [[ "$next_action" =~ ^[0-2]$ ]]; then
                    break
                else
                    log_warn "Invalid selection. Please enter 0, 1, or 2."
                fi
            done

            if [ "$next_action" -eq 0 ]; then
                log_info "Exiting. Backups preserved in: $BACKUP_DIR"
                log_info "Queue file: $QUEUE_FILE"
                cleanup
                exit 0
            elif [ "$next_action" -eq 2 ]; then
                # Process transcode queue
                mode=2
                break
            else
                # Backup another disc - eject current disc
                echo
                eject_disc
                echo
                echo "Please insert the next disc"
                read -p "Press Enter when ready..."
                echo
                echo "========================================"
                echo

                # Get movie title for next disc
                read -p "Enter movie title to search: " search_query

                if [ -z "$search_query" ]; then
                    log_error "No title entered"
                    exit 1
                fi

                # Search TMDb and get metadata
                if ! search_tmdb "$search_query"; then
                    log_error "Failed to get movie metadata"
                    exit 1
                fi

                # Create filename base (using original title)
                local safe_title=$(sanitize_filename "$MOVIE_TITLE_ORIGINAL")
                FILENAME_BASE="${safe_title} (${MOVIE_YEAR}) {${IMDB_ID}}"

                echo
                log_info "Final filename will be: ${FILENAME_BASE}.mkv"
                echo

                # Select encoding preset for this disc
                echo "Select encoding preset for this disc:"
                echo "1. DVD to x264 MKV (SD/DVD content - CRF 20, veryslow, ~60-90min)"
                echo "   - x264 veryslow, film tune, quality 20, multi-pass"
                echo "   - AC3 audio passthrough, subtitle scan (not burned)"
                echo
                echo "2. BluRay to x264 MKV (1080p content - CRF 24, veryslow, ~90-120min)"
                echo "   - x264 veryslow, film tune, quality 24, multi-pass"
                echo "   - AC3 audio encode, subtitle scan (not burned)"
                echo
                echo "3. BluRay 4K to x265 (4K UHD content - CRF 24, slow, ~120-180min)"
                echo "   - x265 10-bit slow, quality 24, multi-pass"
                echo "   - AC3 audio passthrough, subtitle scan (not burned)"
                echo

                local preset_choice=""
                while [[ ! "$preset_choice" =~ ^[1-3]$ ]]; do
                    read -p "Enter preset number (1-3, required): " preset_choice
                    if [[ ! "$preset_choice" =~ ^[1-3]$ ]]; then
                        log_warn "Invalid selection. Please enter 1, 2, or 3"
                    fi
                done

                case "$preset_choice" in
                    1)
                        SELECTED_PRESET="custom_x264_mkv2"
                        log_info "Selected preset: DVD to x264 MKV"
                        ;;
                    2)
                        SELECTED_PRESET="bluray_1080p_x264"
                        log_info "Selected preset: BluRay to x264 MKV"
                        ;;
                    3)
                        SELECTED_PRESET="bluray_4k_x265"
                        log_info "Selected preset: BluRay 4K to x265"
                        ;;
                esac
                echo

                # Continue loop for next backup
            fi
        done
    fi

    # Mode 2: Process transcode queue
    if [ "$mode" -eq 2 ]; then
        # Eject disc before starting transcode (no disc needed for encoding)
        echo
        eject_disc
        echo

        if ! process_transcode_queue; then
            log_error "Queue processing failed"
            cleanup
            exit 1
        fi

        # Cleanup
        cleanup

        echo
        log_info "=== All Processing Complete ==="
        exit 0
    fi
}

# Run main function
main "$@"