#!/bin/bash
# =============================================================================
# Q-Feeds Blocklist Installer Script (nftables Edition)
# =============================================================================
# Copyright (c) 2024 Q-Feeds
# All rights reserved.
#
# This script installs and configures the Q-Feeds Blocklist on your system,
# using nftables. It sets up the necessary dependencies, configuration files,
# and scheduled tasks to keep your system protected with the latest threat
# intelligence data provided by Q-Feeds.
#
# Before proceeding, you must accept the Terms & Conditions and End-User License
# Agreement (EULA) as published on https://qfeeds.com/terms
#
# Redistribution and use in source and binary forms, with or without
# modification, are strictly prohibited without prior written consent from
# Q-Feeds.
# =============================================================================

set -e

# ================================
# File and Directory Locations
# ================================
CONFIG_FILE="/etc/qfeeds/qfeeds_config.conf"
LOG_FILE="/var/log/qfeeds_blocklist.log"
MAIN_SCRIPT="/usr/local/bin/update_qfeeds_blocklist.sh"
INSTALLER_SCRIPT="/usr/local/bin/install_qfeeds.sh"
LOCK_FILE="/var/lock/qfeeds_blocklist.lock"
NFT_RESTORE_SERVICE="/etc/systemd/system/ipset-restore.service"  # Not really used now, but left for reference
CRON_CMD="/usr/local/bin/update_qfeeds_blocklist.sh"

# ================================
# Functions
# ================================

accept_terms() {
    echo "================================================================================"
    echo "Q-Feeds Terms & Conditions and End-User License Agreement (EULA)"
    echo "================================================================================"
    echo "Before using this software, you must accept the Terms & Conditions and EULA"
    echo "as published on https://qfeeds.com/terms"
    echo
    echo "Please review the Terms & Conditions and EULA at the following URL:"
    echo "https://qfeeds.com/terms"
    echo
    read -rp "Do you accept the Terms & Conditions and EULA? (yes/no): " response
    case "$response" in
        [yY][eE][sS]|[yY])
            echo "Thank you for accepting the Terms & Conditions and EULA."
            ;;
        *)
            echo "You must accept the Terms & Conditions and EULA to proceed."
            exit 1
            ;;
    esac
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID=$ID
        DISTRO_VERSION=$VERSION_ID
    else
        echo "Unsupported Linux distribution."
        exit 1
    fi
}

install_dependencies() {
    echo "Installing required packages..."
    case "$DISTRO_ID" in
        ubuntu|debian)
            apt-get update
            apt-get install -y nftables curl flock
            ;;
        centos|rhel|almalinux|rocky)
            yum install -y nftables curl util-linux
            ;;
        fedora)
            dnf install -y nftables curl util-linux
            ;;
        opensuse-leap|sles)
            zypper install -y nftables curl util-linux
            ;;
        arch)
            pacman -Sy --noconfirm nftables curl util-linux
            ;;
        *)
            echo "Unsupported Linux distribution: $DISTRO_ID"
            echo "Please install the required packages manually."
            exit 1
            ;;
    esac

    # Check if flock is installed
    if ! command -v flock &>/dev/null; then
        echo "Error: flock command is not installed."
        exit 1
    fi
    echo "Dependencies installed."
}

configure_script() {
    echo "Configuring Q-Feeds Blocklist Script..."

    # Create configuration directory
    mkdir -p /etc/qfeeds

    # Prompt for API Token
    read -rp "Enter your Q-Feeds API Token: " API_TOKEN
    if [ -z "$API_TOKEN" ]; then
        echo "Error: API Token cannot be empty."
        exit 1
    fi

    # Prompt for optional settings
    read -rp "Enter feed type [default: malware_ip]: " FEED_TYPE
    FEED_TYPE=${FEED_TYPE:-malware_ip}

    read -rp "Enter the limit of IPs to fetch (leave empty for no limit): " LIMIT

    # Directional blocking options
    read -rp "Block INCOMING connections from malicious IPs? [Y/n]: " BLOCK_INCOMING
    case "$BLOCK_INCOMING" in
        [nN][oO]|[nN])
            BLOCK_INCOMING="no"
            ;;
        *)
            BLOCK_INCOMING="yes"
            ;;
    esac

    read -rp "Block OUTGOING connections to malicious IPs? [y/N]: " BLOCK_OUTGOING
    case "$BLOCK_OUTGOING" in
        [yY][eE][sS]|[yY])
            BLOCK_OUTGOING="yes"
            ;;
        *)
            BLOCK_OUTGOING="no"
            ;;
    esac

    # Optional whitelist
    read -rp "Configure a whitelist of IPs/CIDRs that must NEVER be blocked? [y/N]: " USE_WHITELIST
    WHITELIST_V4=""
    WHITELIST_V6=""
    case "$USE_WHITELIST" in
        [yY][eE][sS]|[yY])
            read -rp "Enter IPv4 whitelist (comma-separated, e.g. 1.2.3.4,5.6.7.8) [leave empty for none]: " WHITELIST_V4
            read -rp "Enter IPv6 whitelist (comma-separated, e.g. 2001:db8::1,2001:db8::2) [leave empty for none]: " WHITELIST_V6
            ;;
        *)
            ;;
    esac

    # Create configuration file
    cat > "$CONFIG_FILE" <<EOF
# Q-Feeds Blocklist Configuration

# API Token (required)
API_TOKEN="$API_TOKEN"

# Feed Type (optional)
FEED_TYPE="$FEED_TYPE"

# Limit of IPs to fetch (optional)
LIMIT=$LIMIT

# Directional blocking options
BLOCK_INCOMING="$BLOCK_INCOMING"
BLOCK_OUTGOING="$BLOCK_OUTGOING"

# Optional whitelist (comma-separated IP/CIDR entries)
WHITELIST_V4="$WHITELIST_V4"
WHITELIST_V6="$WHITELIST_V6"

# Log File Location
LOG_FILE="$LOG_FILE"

# NFTables Set Names (blacklists)
NFT_SET_NAME_V4="qfeeds_blacklist_v4"
NFT_SET_NAME_V6="qfeeds_blacklist_v6"

# NFTables Set Names (whitelists)
NFT_WHITELIST_SET_NAME_V4="qfeeds_whitelist_v4"
NFT_WHITELIST_SET_NAME_V6="qfeeds_whitelist_v6"
EOF

    chmod 600 "$CONFIG_FILE"

    echo "Configuration file created at $CONFIG_FILE"
}

install_main_script() {
    echo "Installing main script..."

    # Create the main script file with embedded content
    cat > "$MAIN_SCRIPT" <<'EOF'
#!/bin/bash
# =============================================================================
# Q-Feeds Blocklist Update Script (nftables)
# =============================================================================
# This script fetches the latest threat intelligence data from Q-Feeds and
# updates nftables sets to block malicious IP addresses (both IPv4 and IPv6).
# =============================================================================

export PATH=$PATH:/sbin:/usr/sbin
set -e

LOG() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $1" | tee -a "$LOG_FILE"
}

cleanup() {
    rm -f "$TEMP_IPS" "$TEMP_RESPONSE"
    LOG "Cleaned up temporary files."
}

trap cleanup EXIT

# Acquire lock to prevent multiple instances
exec 200>/var/lock/qfeeds_blocklist.lock
flock -n 200 || { LOG "Another instance is running. Exiting."; exit 1; }

check_dependencies() {
    local missing=0
    for cmd in nft curl flock; do
        if ! command -v "$cmd" &>/dev/null; then
            LOG "Error: Required command '$cmd' is not installed."
            missing=$((missing + 1))
        fi
    done
    if [ "$missing" -ne 0 ]; then
        LOG "Please install the missing dependencies and re-run the script."
        exit 1
    fi
}

setup_nft() {
    # Create tables and sets if they don't exist; otherwise, flush them.

    # For IPv4
    if nft list table ip qfeeds &>/dev/null; then
        # Table exists, flush blacklist set or re-create
        if nft list set ip qfeeds "$NFT_SET_NAME_V4" &>/dev/null; then
            nft flush set ip qfeeds "$NFT_SET_NAME_V4"
            LOG "Flushed existing nft blacklist set: $NFT_SET_NAME_V4"
        else
            nft add set ip qfeeds "$NFT_SET_NAME_V4" { type ipv4_addr\; flags interval\; }
            LOG "Created nft blacklist set: $NFT_SET_NAME_V4"
        fi

        # Whitelist set for IPv4
        if nft list set ip qfeeds "$NFT_WHITELIST_SET_NAME_V4" &>/dev/null; then
            nft flush set ip qfeeds "$NFT_WHITELIST_SET_NAME_V4"
            LOG "Flushed existing nft whitelist set: $NFT_WHITELIST_SET_NAME_V4"
        else
            nft add set ip qfeeds "$NFT_WHITELIST_SET_NAME_V4" { type ipv4_addr\; flags interval\; }
            LOG "Created nft whitelist set: $NFT_WHITELIST_SET_NAME_V4"
        fi
    else
        nft add table ip qfeeds
        nft add set ip qfeeds "$NFT_SET_NAME_V4" { type ipv4_addr\; flags interval\; }
        nft add set ip qfeeds "$NFT_WHITELIST_SET_NAME_V4" { type ipv4_addr\; flags interval\; }
        LOG "Created nft table qfeeds and IPv4 sets."
    fi

    # For IPv6
    if nft list table ip6 qfeeds &>/dev/null; then
        # Table exists, flush blacklist set or re-create
        if nft list set ip6 qfeeds "$NFT_SET_NAME_V6" &>/dev/null; then
            nft flush set ip6 qfeeds "$NFT_SET_NAME_V6"
            LOG "Flushed existing nft blacklist set: $NFT_SET_NAME_V6"
        else
            nft add set ip6 qfeeds "$NFT_SET_NAME_V6" { type ipv6_addr\; flags interval\; }
            LOG "Created nft blacklist set: $NFT_SET_NAME_V6"
        fi

        # Whitelist set for IPv6
        if nft list set ip6 qfeeds "$NFT_WHITELIST_SET_NAME_V6" &>/dev/null; then
            nft flush set ip6 qfeeds "$NFT_WHITELIST_SET_NAME_V6"
            LOG "Flushed existing nft whitelist set: $NFT_WHITELIST_SET_NAME_V6"
        else
            nft add set ip6 qfeeds "$NFT_WHITELIST_SET_NAME_V6" { type ipv6_addr\; flags interval\; }
            LOG "Created nft whitelist set: $NFT_WHITELIST_SET_NAME_V6"
        fi
    else
        nft add table ip6 qfeeds
        nft add set ip6 qfeeds "$NFT_SET_NAME_V6" { type ipv6_addr\; flags interval\; }
        nft add set ip6 qfeeds "$NFT_WHITELIST_SET_NAME_V6" { type ipv6_addr\; flags interval\; }
        LOG "Created nft ip6 qfeeds table and IPv6 sets."
    fi

    # Chains and rules for IPv4
    if [ "$BLOCK_INCOMING" = "yes" ]; then
        if ! nft list chain ip qfeeds input-chain &>/dev/null; then
            nft add chain ip qfeeds input-chain { type filter hook input priority 0\; policy accept\; }
            LOG "Created IPv4 input-chain in qfeeds table."
        fi
        # Ensure whitelist-then-blacklist rules exist for input chain (IPv4)
        if ! nft list chain ip qfeeds input-chain | grep -q "ip s @$NFT_WHITELIST_SET_NAME_V4 accept"; then
            nft add rule ip qfeeds input-chain ip s @${NFT_WHITELIST_SET_NAME_V4} accept
        fi
        if ! nft list chain ip qfeeds input-chain | grep -q "ip s @$NFT_SET_NAME_V4 drop"; then
            nft add rule ip qfeeds input-chain ip s @${NFT_SET_NAME_V4} drop
        fi
    fi

    if [ "$BLOCK_OUTGOING" = "yes" ]; then
        if ! nft list chain ip qfeeds output-chain &>/dev/null; then
            nft add chain ip qfeeds output-chain { type filter hook output priority 0\; policy accept\; }
            LOG "Created IPv4 output-chain in qfeeds table."
        fi
        # Ensure whitelist-then-blacklist rules exist for output chain (IPv4)
        if ! nft list chain ip qfeeds output-chain | grep -q "ip d @$NFT_WHITELIST_SET_NAME_V4 accept"; then
            nft add rule ip qfeeds output-chain ip d @${NFT_WHITELIST_SET_NAME_V4} accept
        fi
        if ! nft list chain ip qfeeds output-chain | grep -q "ip d @$NFT_SET_NAME_V4 drop"; then
            nft add rule ip qfeeds output-chain ip d @${NFT_SET_NAME_V4} drop
        fi
    fi

    # Chains and rules for IPv6
    if [ "$BLOCK_INCOMING" = "yes" ]; then
        if ! nft list chain ip6 qfeeds input-chain &>/dev/null; then
            nft add chain ip6 qfeeds input-chain { type filter hook input priority 0\; policy accept\; }
            LOG "Created IPv6 input-chain in qfeeds table."
        fi
        if ! nft list chain ip6 qfeeds input-chain | grep -q "ip6 s @$NFT_WHITELIST_SET_NAME_V6 accept"; then
            nft add rule ip6 qfeeds input-chain ip6 s @${NFT_WHITELIST_SET_NAME_V6} accept
        fi
        if ! nft list chain ip6 qfeeds input-chain | grep -q "ip6 s @$NFT_SET_NAME_V6 drop"; then
            nft add rule ip6 qfeeds input-chain ip6 s @${NFT_SET_NAME_V6} drop
        fi
    fi

    if [ "$BLOCK_OUTGOING" = "yes" ]; then
        if ! nft list chain ip6 qfeeds output-chain &>/dev/null; then
            nft add chain ip6 qfeeds output-chain { type filter hook output priority 0\; policy accept\; }
            LOG "Created IPv6 output-chain in qfeeds table."
        fi
        if ! nft list chain ip6 qfeeds output-chain | grep -q "ip6 d @$NFT_WHITELIST_SET_NAME_V6 accept"; then
            nft add rule ip6 qfeeds output-chain ip6 d @${NFT_WHITELIST_SET_NAME_V6} accept
        fi
        if ! nft list chain ip6 qfeeds output-chain | grep -q "ip6 d @$NFT_SET_NAME_V6 drop"; then
            nft add rule ip6 qfeeds output-chain ip6 d @${NFT_SET_NAME_V6} drop
        fi
    fi
}

fetch_blocklist() {
    LOG "Fetching blocklist from Q-Feeds..."
    http_status=$(curl -s -w "%{http_code}" -m 300 -o "$TEMP_RESPONSE" "$API_URL")
    if [ "$http_status" -ne 200 ]; then
        LOG "Error: Failed to fetch blocklist. HTTP status code: $http_status"
        LOG "Response:"
        cat "$TEMP_RESPONSE" | tee -a "$LOG_FILE"
        exit 1
    fi
    if [ ! -s "$TEMP_RESPONSE" ]; then
        LOG "Error: Blocklist response is empty."
        exit 1
    fi
    LOG "Successfully fetched blocklist."
}

parse_ips() {
    LOG "Parsing IP addresses from the response..."
    cp "$TEMP_RESPONSE" "$TEMP_IPS"

    # Validate that the file has at least something that looks like IP addresses
    if ! grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|:' "$TEMP_IPS"; then
        LOG "Error: No valid IP addresses found in the response."
        exit 1
    fi

    LOG "Parsed $(wc -l < "$TEMP_IPS") IP addresses (including potential invalid lines)."
}

update_nft_sets() {
    LOG "Updating nft sets: $NFT_SET_NAME_V4 (IPv4) and $NFT_SET_NAME_V6 (IPv6)"

    # Add each IP to its respective set
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        [[ "$ip" =~ ^# ]] && continue

        # IPv4 check
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            nft add element ip qfeeds "$NFT_SET_NAME_V4" { "$ip" }
        # IPv6 check
        elif [[ "$ip" =~ : ]]; then
            nft add element ip6 qfeeds "$NFT_SET_NAME_V6" { "$ip" }
        else
            LOG "Warning: Invalid IP format skipped - $ip"
        fi
    done < "$TEMP_IPS"

    LOG "nft sets updated with the latest IPs."
}

update_whitelist_sets() {
    LOG "Updating nft whitelist sets (if configured)."

    # IPv4 whitelist
    if [ -n "$WHITELIST_V4" ]; then
        echo "$WHITELIST_V4" | tr ',' '\n' | while IFS= read -r ip; do
            ip_trimmed=$(echo "$ip" | xargs)
            [ -z "$ip_trimmed" ] && continue
            nft add element ip qfeeds "$NFT_WHITELIST_SET_NAME_V4" { "$ip_trimmed" }
        done
        LOG "IPv4 whitelist set $NFT_WHITELIST_SET_NAME_V4 updated."
    else
        LOG "No IPv4 whitelist configured."
    fi

    # IPv6 whitelist
    if [ -n "$WHITELIST_V6" ]; then
        echo "$WHITELIST_V6" | tr ',' '\n' | while IFS= read -r ip; do
            ip_trimmed=$(echo "$ip" | xargs)
            [ -z "$ip_trimmed" ] && continue
            nft add element ip6 qfeeds "$NFT_WHITELIST_SET_NAME_V6" { "$ip_trimmed" }
        done
        LOG "IPv6 whitelist set $NFT_WHITELIST_SET_NAME_V6 updated."
    else
        LOG "No IPv6 whitelist configured."
    fi
}

save_nft_rules() {
    # Depending on your distro, netfilter-persistent might work with nft
    # or you can manually save to /etc/nftables.conf
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
        LOG "Saved nftables rules using netfilter-persistent."
    else
        LOG "Note: Persist your nft rules with something like:"
        LOG "  nft list ruleset > /etc/nftables.conf"
    fi
}

# ================================
# Main Execution
# ================================
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

# Load Configuration
CONFIG_FILE="/etc/qfeeds/qfeeds_config.conf"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found at $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# Validate required variables
[ -z "$API_TOKEN" ] && { echo "Error: API_TOKEN is not set in the config file."; exit 1; }
[ -z "$LOG_FILE" ] && LOG_FILE="/var/log/qfeeds_blocklist.log"

# Default directional options if not set (backwards compatibility)
[ -z "$BLOCK_INCOMING" ] && BLOCK_INCOMING="yes"
[ -z "$BLOCK_OUTGOING" ] && BLOCK_OUTGOING="no"

# Default whitelist set names if not set (backwards compatibility)
[ -z "$NFT_WHITELIST_SET_NAME_V4" ] && NFT_WHITELIST_SET_NAME_V4="qfeeds_whitelist_v4"
[ -z "$NFT_WHITELIST_SET_NAME_V6" ] && NFT_WHITELIST_SET_NAME_V6="qfeeds_whitelist_v6"

# Construct API URL
if [ -z "$LIMIT" ] || [ "$LIMIT" -le 0 ]; then
    API_URL="https://api.qfeeds.com/api?feed_type=${FEED_TYPE}&api_token=${API_TOKEN}"
else
    API_URL="https://api.qfeeds.com/api?feed_type=${FEED_TYPE}&api_token=${API_TOKEN}&limit=${LIMIT}"
fi

TEMP_IPS=$(mktemp /tmp/qfeeds_ips.XXXXXX)
TEMP_RESPONSE=$(mktemp /tmp/qfeeds_response.XXXXXX)

check_dependencies
setup_nft
fetch_blocklist
parse_ips
update_nft_sets
update_whitelist_sets
save_nft_rules

LOG "Q-Feeds nftables blocklist update completed successfully."
exit 0
EOF

    chmod 700 "$MAIN_SCRIPT"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    echo "Main script installed at $MAIN_SCRIPT"
}

setup_cron() {
    echo "Setting up cron job..."
    read -rp "Enter cron schedule (e.g., '*/20 * * * *') [default: */20 * * * *]: " CRON_SCHEDULE
    CRON_SCHEDULE=${CRON_SCHEDULE:-"*/20 * * * *"}

    # Remove any existing lines for this script, then add
    (crontab -l 2>/dev/null | grep -v "$CRON_CMD"; echo "$CRON_SCHEDULE $CRON_CMD") | crontab -
    echo "Cron job added (runs $CRON_CMD on schedule '$CRON_SCHEDULE')."
}

finalize_installation() {
    echo "Finalizing installation..."
    /usr/local/bin/update_qfeeds_blocklist.sh
    echo "Installation and initial run completed."
}

# ================================
# Main Execution (Installer)
# ================================
echo "Q-Feeds Blocklist Installer (nftables Edition)"

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

accept_terms
detect_distro
echo "Detected Linux distribution: $DISTRO_ID $DISTRO_VERSION"

install_dependencies
configure_script
install_main_script
setup_cron
finalize_installation

echo "Q-Feeds Blocklist setup with nftables is complete!"
exit 0
m