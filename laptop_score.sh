#!/usr/bin/env bash
# =============================================================================
# laptop_score.sh — Hardware Evaluation Script
# =============================================================================
# Use case : Video conferencing (Zoom, Google Meet, Jitsi) + OBS Studio
#            with goXLR, Elgato Stream Deck, Elgato 4K Webcam
#
# Scoring weights:
#   CPU  40%  — OBS encoding, Zoom/Meet processing, multi-app workload
#   RAM  35%  — Multiple heavy apps running simultaneously
#   GPU  10%  — Display rendering, potential hardware encode/decode
#   Disk 10%  — OBS recording, app loading
#   USB   5%  — goXLR + Stream Deck + Elgato webcam all need USB 3.x
#
# Final score: 0–1000  (higher is better)
#
# Requires  : Ubuntu/Debian-based Linux
# Sudo      : Asked once upfront, used for apt and hdparm (optional)
# Cleanup   : All installed packages are removed on exit
# =============================================================================

set -uo pipefail

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Global state ------------------------------------------------------------
PACKAGES_INSTALLED=()
SUDO_GRANTED=false
SUDO_KEEPALIVE_PID=""

SCORE_CPU=0
SCORE_RAM=0
SCORE_GPU=0
SCORE_DISK=0
SCORE_USB=0

# =============================================================================
# UTILITIES
# =============================================================================

print_header() {
    echo -e "\n${CYAN}${BOLD}━━━  $1  ━━━${NC}\n"
}

print_info() {
    echo -e "  ${GREEN}→${NC}  $1"
}

print_warn() {
    echo -e "  ${YELLOW}⚠${NC}   $1"
}

print_error() {
    echo -e "  ${RED}✗${NC}   $1"
}

# Clamp an integer to the range 0–100
clamp() {
    local val="${1:-0}"
    # Ensure val is an integer
    val=$(printf '%d' "$val" 2>/dev/null || echo 0)
    if   (( val > 100 )); then echo 100
    elif (( val < 0   )); then echo 0
    else                       echo "$val"
    fi
}

# Install a single apt package; track it for cleanup.
# Silently skips if already installed. Returns 1 if sudo not granted.
install_package() {
    local pkg="$1"

    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        print_info "${pkg} already installed — no action needed."
        return 0
    fi

    if [[ "$SUDO_GRANTED" != true ]]; then
        print_warn "Skipping ${pkg} — sudo not available."
        return 1
    fi

    print_info "Installing ${pkg}…"
    if sudo apt-get install -y -qq "$pkg" >/dev/null 2>&1; then
        PACKAGES_INSTALLED+=("$pkg")
        return 0
    else
        print_error "Could not install ${pkg}."
        return 1
    fi
}

# Remove everything we installed, then run autoremove.
cleanup() {
    # Kill the sudo keep-alive background process if it exists
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi

    # Remove temp disk benchmark file if it somehow survived
    rm -f /tmp/laptop_score_disktest_$$ 2>/dev/null || true

    if [[ ${#PACKAGES_INSTALLED[@]} -eq 0 ]]; then
        return
    fi

    print_header "Cleanup"
    print_info "Removing packages installed by this script: ${PACKAGES_INSTALLED[*]}"

    if [[ "$SUDO_GRANTED" == true ]]; then
        sudo apt-get remove -y -qq "${PACKAGES_INSTALLED[@]}" 2>/dev/null || true
        sudo apt-get autoremove -y -qq 2>/dev/null || true
        print_info "Cleanup complete."
    else
        print_warn "Cannot remove packages without sudo."
        print_warn "Please run manually:  sudo apt remove ${PACKAGES_INSTALLED[*]}"
    fi
}

trap cleanup EXIT

# =============================================================================
# SUDO SETUP
# =============================================================================

setup_sudo() {
    echo -e "${YELLOW}${BOLD}Sudo access${NC}"
    echo
    echo -e "  This script would like elevated privileges for:"
    echo -e "  • Installing benchmark tools  (sysbench, usbutils, mesa-utils)"
    echo -e "  • Removing those tools afterwards"
    echo -e "  • Reading disk hardware info  (hdparm — optional)"
    echo
    echo -ne "  Grant sudo access for this session? [y/N] "
    read -r sudo_answer

    if [[ "$sudo_answer" =~ ^[Yy]$ ]]; then
        if sudo -v 2>/dev/null; then
            SUDO_GRANTED=true
            echo -e "  ${GREEN}✓${NC}  Sudo granted.\n"

            # Keep the sudo ticket alive in the background
            ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 $$ 2>/dev/null || exit; done ) &
            SUDO_KEEPALIVE_PID=$!
        else
            echo -e "  ${RED}✗${NC}  Authentication failed. Continuing without sudo.\n"
        fi
    else
        echo -e "  ${YELLOW}⚠${NC}   Continuing without sudo. Some tests will be limited.\n"
    fi
}

# =============================================================================
# BENCHMARK — CPU
# =============================================================================

benchmark_cpu() {
    print_header "CPU"

    local cpu_model threads
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
    threads=$(nproc 2>/dev/null || echo 1)

    print_info "Model   : ${cpu_model}"
    print_info "Threads : ${threads}"

    # Try to install sysbench
    if ! command -v sysbench &>/dev/null; then
        install_package "sysbench" || true
    fi

    if command -v sysbench &>/dev/null; then
        print_info "Running sysbench CPU test (15 seconds, ${threads} threads)…"

        local bench_output
        bench_output=$(sysbench cpu \
            --cpu-max-prime=20000 \
            --threads="$threads" \
            --time=15 \
            run 2>/dev/null || echo "")

        local events_per_sec
        events_per_sec=$(echo "$bench_output" \
            | grep "events per second" \
            | awk '{print $NF}' \
            | cut -d. -f1)
        events_per_sec=$(printf '%d' "${events_per_sec:-0}" 2>/dev/null || echo 0)

        print_info "Events/sec : ${events_per_sec}"

        # Scoring reference (multi-threaded, prime 20000, 15 s):
        #   ~500  ev/s  → score ≈ 10  (very old single-core)
        #   ~2 000 ev/s → score ≈ 30  (old dual-core)
        #   ~5 000 ev/s → score ≈ 50  (marginal for use case)
        #   ~10 000 ev/s→ score ≈ 70  (adequate)
        #   ~18 000 ev/s→ score ≈ 100 (comfortable)
        # Linear: score = events_per_sec / 180, capped at 100
        SCORE_CPU=$(clamp $(( events_per_sec / 180 )))

    else
        # Fallback: heuristic from /proc/cpuinfo
        print_warn "sysbench unavailable. Using /proc/cpuinfo heuristic (less accurate)."
        local mhz cores
        mhz=$(grep -m1 "cpu MHz" /proc/cpuinfo 2>/dev/null | awk '{print $4}' | cut -d. -f1 || echo 1000)
        cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo 1)
        mhz=$(printf '%d' "${mhz:-1000}" 2>/dev/null || echo 1000)
        cores=$(printf '%d' "${cores:-1}" 2>/dev/null || echo 1)
        SCORE_CPU=$(clamp $(( mhz * cores / 45000 )))
        print_warn "Heuristic score — run with sysbench for accuracy."
    fi

    print_info "CPU score : ${SCORE_CPU}/100"
}

# =============================================================================
# BENCHMARK — RAM
# =============================================================================

benchmark_ram() {
    print_header "RAM"

    # --- Size score ---
    local total_kb total_gb
    total_kb=$(grep "^MemTotal" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)
    total_gb=$(( total_kb / 1024 / 1024 ))
    print_info "Total RAM : ${total_gb} GB"

    local size_score
    if   (( total_gb >= 32 )); then size_score=100
    elif (( total_gb >= 24 )); then size_score=90
    elif (( total_gb >= 16 )); then size_score=80
    elif (( total_gb >= 12 )); then size_score=70
    elif (( total_gb >= 8  )); then size_score=55
    elif (( total_gb >= 6  )); then size_score=38
    elif (( total_gb >= 4  )); then size_score=22
    else                            size_score=10
    fi
    print_info "Size score : ${size_score}/100"

    # --- Speed score (sysbench memory) ---
    local speed_score=50
    if command -v sysbench &>/dev/null; then
        print_info "Running sysbench memory bandwidth test…"

        local mem_output
        mem_output=$(sysbench memory \
            --memory-block-size=1M \
            --memory-total-size=4G \
            --threads="$(nproc)" \
            run 2>/dev/null || echo "")

        local mib_sec
        mib_sec=$(echo "$mem_output" \
            | grep "MiB/sec" \
            | grep -oE '[0-9]+\.[0-9]+' \
            | tail -1 \
            | cut -d. -f1)
        mib_sec=$(printf '%d' "${mib_sec:-0}" 2>/dev/null || echo 0)

        print_info "Bandwidth  : ${mib_sec} MiB/s"

        # 5 000 MiB/s → score 25  (DDR3 single channel)
        # 10 000 MiB/s → score 50  (DDR4 single channel)
        # 20 000 MiB/s → score 100 (DDR4 dual channel)
        speed_score=$(clamp $(( mib_sec / 200 )))
        print_info "Speed score : ${speed_score}/100"
    else
        print_warn "sysbench unavailable. Using default RAM speed score."
    fi

    # Combined: 70% size, 30% speed
    SCORE_RAM=$(clamp $(( (size_score * 70 + speed_score * 30) / 100 )))
    print_info "RAM score : ${SCORE_RAM}/100"
}

# =============================================================================
# BENCHMARK — GPU
# =============================================================================

benchmark_gpu() {
    print_header "GPU"

    local gpu_lines
    gpu_lines=$(lspci 2>/dev/null | grep -iE "vga|3d controller|display controller" || echo "")

    if [[ -z "$gpu_lines" ]]; then
        print_warn "No GPU detected via lspci."
        SCORE_GPU=20
        return
    fi

    echo "$gpu_lines" | while IFS= read -r line; do
        print_info "Detected : ${line}"
    done

    local score=25  # baseline for unknown integrated

    if echo "$gpu_lines" | grep -qi "nvidia"; then
        print_info "Type : Nvidia (dedicated)"
        score=80
        if command -v nvidia-smi &>/dev/null; then
            local gpu_name
            gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "")
            [[ -n "$gpu_name" ]] && print_info "Name : ${gpu_name}"
            score=88
        fi

    elif echo "$gpu_lines" | grep -qi "amd\|radeon\|amdgpu"; then
        print_info "Type : AMD (dedicated or integrated)"
        score=72

    elif echo "$gpu_lines" | grep -qi "intel"; then
        print_info "Type : Intel integrated"
        # Try to infer generation from CPU model string
        local cpu_str gen
        cpu_str=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null || echo "")
        gen=$(echo "$cpu_str" | grep -oP 'i[357]-([0-9]{4,5})' | grep -oP '[0-9]{4,5}' | head -1 | cut -c1-1)
        gen=$(printf '%d' "${gen:-0}" 2>/dev/null || echo 0)
        if   (( gen >= 8 )); then score=48   # 8th gen+ Intel graphics
        elif (( gen >= 6 )); then score=38   # 6th–7th gen
        elif (( gen >= 4 )); then score=28   # Haswell/Broadwell
        else                     score=20
        fi
    fi

    # Optional: bump score slightly if OpenGL 4.x is available
    if ! command -v glxinfo &>/dev/null; then
        install_package "mesa-utils" 2>/dev/null || true
    fi

    if command -v glxinfo &>/dev/null && [[ -n "${DISPLAY:-}" ]]; then
        local gl_ver
        gl_ver=$(glxinfo 2>/dev/null \
            | grep "OpenGL version" \
            | grep -oP '[0-9]+' \
            | head -1 || echo 0)
        gl_ver=$(printf '%d' "${gl_ver:-0}" 2>/dev/null || echo 0)
        print_info "OpenGL version : ${gl_ver}.x"
        (( gl_ver >= 4 )) && score=$(clamp $(( score + 8 )))
    else
        print_warn "glxinfo skipped (no DISPLAY or mesa-utils unavailable)."
    fi

    SCORE_GPU=$(clamp "$score")
    print_info "GPU score : ${SCORE_GPU}/100"
}

# =============================================================================
# BENCHMARK — DISK
# =============================================================================

benchmark_disk() {
    print_header "Disk"

    local test_file="/tmp/laptop_score_disktest_$$"

    # Detect root disk and whether it is rotational (HDD) or not (SSD/NVMe)
    local root_dev root_disk disk_type rotational
    root_dev=$(df / 2>/dev/null | tail -1 | awk '{print $1}')
    # Strip partition suffix: /dev/sda3 → sda, /dev/nvme0n1p2 → nvme0n1
    root_disk=$(basename "$root_dev" | sed 's/p\?[0-9]*$//')
    disk_type="Unknown"
    if [[ -f "/sys/block/${root_disk}/queue/rotational" ]]; then
        rotational=$(cat "/sys/block/${root_disk}/queue/rotational" 2>/dev/null || echo 1)
        if [[ "$rotational" == "0" ]]; then disk_type="SSD / NVMe"
        else                               disk_type="HDD"
        fi
    fi
    print_info "Root device : /dev/${root_disk}  (${disk_type})"

    # --- Write speed ---
    print_info "Testing sequential write speed (512 MB)…"
    local write_output write_mb
    write_output=$(dd if=/dev/zero \
        of="$test_file" \
        bs=1M count=512 \
        conv=fdatasync \
        2>&1 1>/dev/null || echo "")

    # dd prints speed to stderr in the form "X MB/s" or "X GB/s"
    write_mb=0
    if echo "$write_output" | grep -qiP "GB/s"; then
        local gb
        gb=$(echo "$write_output" | grep -oP '[0-9]+\.?[0-9]*\s*GB/s' | grep -oP '[0-9]+\.?[0-9]*' | head -1)
        write_mb=$(echo "$gb * 1000" | bc 2>/dev/null | cut -d. -f1 || echo 0)
    elif echo "$write_output" | grep -qiP "MB/s"; then
        write_mb=$(echo "$write_output" | grep -oP '[0-9]+\.?[0-9]*\s*MB/s' | grep -oP '[0-9]+\.?[0-9]*' | head -1 | cut -d. -f1)
    fi
    write_mb=$(printf '%d' "${write_mb:-0}" 2>/dev/null || echo 0)
    print_info "Write speed : ${write_mb} MB/s"

    # --- Read speed ---
    print_info "Testing sequential read speed (512 MB)…"
    local read_output read_mb
    # Drop the page cache if we can (sudo), then read back the test file
    if [[ "$SUDO_GRANTED" == true ]]; then
        sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    fi
    read_output=$(dd if="$test_file" \
        of=/dev/null \
        bs=1M \
        2>&1 1>/dev/null || echo "")

    read_mb=0
    if echo "$read_output" | grep -qiP "GB/s"; then
        local gb
        gb=$(echo "$read_output" | grep -oP '[0-9]+\.?[0-9]*\s*GB/s' | grep -oP '[0-9]+\.?[0-9]*' | head -1)
        read_mb=$(echo "$gb * 1000" | bc 2>/dev/null | cut -d. -f1 || echo 0)
    elif echo "$read_output" | grep -qiP "MB/s"; then
        read_mb=$(echo "$read_output" | grep -oP '[0-9]+\.?[0-9]*\s*MB/s' | grep -oP '[0-9]+\.?[0-9]*' | head -1 | cut -d. -f1)
    fi
    read_mb=$(printf '%d' "${read_mb:-0}" 2>/dev/null || echo 0)
    print_info "Read speed  : ${read_mb} MB/s"

    rm -f "$test_file" 2>/dev/null || true

    # Scoring:
    # Use the average of read and write, weighted 40% write / 60% read
    local avg_mb=$(( (write_mb * 40 + read_mb * 60) / 100 ))

    # SSD/NVMe:  100 MB/s = 30,  300 MB/s = 60,  500 MB/s = 80,  1000+ MB/s = 100
    # HDD:        50 MB/s = 30,  100 MB/s = 55,  150 MB/s = 75
    local score
    if [[ "$disk_type" == "SSD / NVMe" ]]; then
        score=$(clamp $(( avg_mb / 11 )))
    else
        score=$(clamp $(( avg_mb * 55 / 100 )))
    fi

    SCORE_DISK=$(clamp "$score")
    print_info "Disk score : ${SCORE_DISK}/100"
}

# =============================================================================
# SCORE — USB
# =============================================================================

score_usb() {
    print_header "USB Ports"

    # Ensure lsusb is available
    if ! command -v lsusb &>/dev/null; then
        install_package "usbutils" || {
            print_warn "usbutils unavailable. Assigning default USB score of 40."
            SCORE_USB=40
            return
        }
    fi

    # lsusb -t shows host controllers with port counts and speeds.
    # Example lines:
    #   /: Bus 02.Port 1: Dev 1, Class=root_hub, Driver=xhci_hcd/4p, 10000M/s
    #   /: Bus 01.Port 1: Dev 1, Class=root_hub, Driver=ehci-pci/2p, 480M/s
    local lsusb_tree
    lsusb_tree=$(lsusb -t 2>/dev/null || echo "")

    # Count total USB 3.x ports by summing port counts on xhci controllers
    local usb3_total=0
    while IFS= read -r line; do
        if echo "$line" | grep -qi "xhci"; then
            local ports
            ports=$(echo "$line" | grep -oP '\d+(?=p,)' | head -1)
            ports=$(printf '%d' "${ports:-0}" 2>/dev/null || echo 0)
            (( usb3_total += ports ))
        fi
    done <<< "$lsusb_tree"

    # Fallback: count xHCI controllers from lspci if lsusb -t gave nothing
    if (( usb3_total == 0 )); then
        local xhci_count
        xhci_count=$(lspci 2>/dev/null | grep -ic "xhci" || echo 0)
        # Assume 2 ports per xHCI controller as a conservative guess
        usb3_total=$(( xhci_count * 2 ))
        [[ $usb3_total -gt 0 ]] && print_warn "lsusb -t gave no port counts; estimating from lspci."
    fi

    local usb2_total=0
    while IFS= read -r line; do
        if echo "$line" | grep -qiE "ehci|ohci|uhci"; then
            local ports
            ports=$(echo "$line" | grep -oP '\d+(?=p,)' | head -1)
            ports=$(printf '%d' "${ports:-0}" 2>/dev/null || echo 0)
            (( usb2_total += ports ))
        fi
    done <<< "$lsusb_tree"

    print_info "USB 3.x physical ports : ${usb3_total}"
    print_info "USB 2.0 physical ports : ${usb2_total}"
    print_info "Note: goXLR + Stream Deck + Elgato webcam need 3 × USB 3.x ports"

    # Scoring — needs at least 3 USB 3.x for the full peripheral set
    local score
    if   (( usb3_total >= 5 )); then score=100
    elif (( usb3_total >= 4 )); then score=95
    elif (( usb3_total >= 3 )); then score=88
    elif (( usb3_total >= 2 )); then score=55
    elif (( usb3_total >= 1 )); then score=25
    else                             score=5
    fi

    SCORE_USB=$(clamp "$score")
    print_info "USB score : ${SCORE_USB}/100"
}

# =============================================================================
# REPORT — NETWORK (informational only, not scored)
# =============================================================================

report_network() {
    print_header "Network  (informational — not scored)"

    # Wired Ethernet
    local eth_found=false
    for iface_path in /sys/class/net/e* /sys/class/net/en*; do
        [[ -e "$iface_path" ]] || continue
        local iface speed carrier
        iface=$(basename "$iface_path")
        speed=$(cat "${iface_path}/speed" 2>/dev/null || echo "")
        carrier=$(cat "${iface_path}/carrier" 2>/dev/null || echo "0")
        if [[ -n "$speed" && "$speed" -gt 0 ]]; then
            print_info "Ethernet : ${iface}  →  ${speed} Mbps  (cable connected)"
            eth_found=true
        elif [[ "$carrier" == "0" ]]; then
            print_info "Ethernet : ${iface}  →  adapter present, no cable"
            eth_found=true
        fi
    done
    $eth_found || print_info "Ethernet : no adapter detected"

    # Wireless
    local wifi_found=false
    for iface_path in /sys/class/net/wl*; do
        [[ -e "$iface_path" ]] || continue
        local iface
        iface=$(basename "$iface_path")
        print_info "WiFi     : ${iface} present"
        wifi_found=true
    done
    $wifi_found || print_info "WiFi     : no adapter detected"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║          Laptop Hardware Scorer  v1.0                    ║"
    echo "  ║  Use case: Video conferencing + OBS + USB peripherals    ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  Host    : $(hostname)"
    echo -e "  Date    : $(date '+%Y-%m-%d %H:%M')"
    echo -e "  Weights : CPU 40% · RAM 35% · GPU 10% · Disk 10% · USB 5%"
    echo

    setup_sudo

    benchmark_cpu
    benchmark_ram
    benchmark_gpu
    benchmark_disk
    score_usb
    report_network

    # -------------------------------------------------------------------------
    # FINAL SCORE
    # -------------------------------------------------------------------------
    print_header "Final Score"

    # Each component is 0–100; multiply by weight/10 to get points out of 1000
    local weighted_cpu  weighted_ram  weighted_gpu
    local weighted_disk weighted_usb  total

    weighted_cpu=$(( SCORE_CPU  * 40 / 10 ))   # max 400
    weighted_ram=$(( SCORE_RAM  * 35 / 10 ))   # max 350
    weighted_gpu=$(( SCORE_GPU  * 10 / 10 ))   # max 100
    weighted_disk=$(( SCORE_DISK * 10 / 10 ))  # max 100
    weighted_usb=$(( SCORE_USB  *  5 / 10 ))   # max  50

    total=$(( weighted_cpu + weighted_ram + weighted_gpu + weighted_disk + weighted_usb ))

    printf "  %-8s  %3d/100  × 40%%  =  %4d pts\n" "CPU"  "$SCORE_CPU"  "$weighted_cpu"
    printf "  %-8s  %3d/100  × 35%%  =  %4d pts\n" "RAM"  "$SCORE_RAM"  "$weighted_ram"
    printf "  %-8s  %3d/100  × 10%%  =  %4d pts\n" "GPU"  "$SCORE_GPU"  "$weighted_gpu"
    printf "  %-8s  %3d/100  × 10%%  =  %4d pts\n" "Disk" "$SCORE_DISK" "$weighted_disk"
    printf "  %-8s  %3d/100  ×  5%%  =  %4d pts\n" "USB"  "$SCORE_USB"  "$weighted_usb"
    echo -e "  ──────────────────────────────────────"
    printf "  %-8s               ${BOLD}%4d / 1000${NC}\n" "TOTAL" "$total"

    # Qualitative rating
    local label
    if   (( total >= 800 )); then label="${GREEN}Excellent${NC} — well suited for this workload"
    elif (( total >= 600 )); then label="${GREEN}Good${NC}      — should handle it comfortably"
    elif (( total >= 400 )); then label="${YELLOW}Marginal${NC}  — may struggle under full load"
    else                          label="${RED}Poor${NC}      — likely to have problems"
    fi
    echo -e "\n  Rating : $label\n"

    # Save a plain-text result file alongside the script (or in $HOME)
    local results_file="${HOME}/laptop_score_$(hostname)_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "Laptop Hardware Score"
        echo "Host   : $(hostname)"
        echo "Date   : $(date)"
        echo "────────────────────────────────"
        printf "CPU    : %3d/100  × 40%%  = %4d pts\n" "$SCORE_CPU"  "$weighted_cpu"
        printf "RAM    : %3d/100  × 35%%  = %4d pts\n" "$SCORE_RAM"  "$weighted_ram"
        printf "GPU    : %3d/100  × 10%%  = %4d pts\n" "$SCORE_GPU"  "$weighted_gpu"
        printf "Disk   : %3d/100  × 10%%  = %4d pts\n" "$SCORE_DISK" "$weighted_disk"
        printf "USB    : %3d/100  ×  5%%  = %4d pts\n" "$SCORE_USB"  "$weighted_usb"
        echo "────────────────────────────────"
        printf "TOTAL  :            %4d / 1000\n" "$total"
    } > "$results_file" 2>/dev/null || true

    [[ -f "$results_file" ]] && print_info "Results saved to: ${results_file}\n"
}

main "$@"
