#!/bin/bash
# =============================================================================
# Q-Feeds Blocklist Installer Script (nftables / iptables+ipset)
# =============================================================================
# Copyright (c) 2026 Q-Feeds
# All rights reserved.
#
# This script installs and configures the Q-Feeds Blocklist on your system,
# using nftables or iptables+ipset (auto-detected). It sets up the necessary
# dependencies, configuration files, and scheduled tasks to keep your system
# protected with the latest threat intelligence data provided by Q-Feeds.
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
    echo "Running this script is your own responsibility. Q-Feeds is not responsible for any damage caused by this script."
    echo
    echo "================================================================================"
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

detect_firewall_backend() {
    if command -v nft >/dev/null 2>&1; then
        BACKEND="nftables"
        echo "Detected nftables (nft command available). Using nftables backend."
    elif command -v iptables >/dev/null 2>&1; then
        BACKEND="iptables"
        echo "nft not found. Detected iptables. Using iptables+ipset backend."
        if ! command -v ipset >/dev/null 2>&1; then
            echo "Note: ipset not found yet — it will be installed with dependencies."
        fi
    else
        echo "Error: Neither 'nft' nor 'iptables' found."
        echo "Please install nftables or iptables before running this installer."
        exit 1
    fi
}

install_dependencies() {
    echo "Installing required packages..."

    local fw_pkgs
    if [ "$BACKEND" = "nftables" ]; then
        fw_pkgs="nftables"
    else
        fw_pkgs="iptables ipset"
    fi

    case "$DISTRO_ID" in
        ubuntu|debian)
            apt-get update
            apt-get install -y $fw_pkgs curl jq util-linux
            ;;
        centos|rhel|almalinux|rocky)
            yum install -y $fw_pkgs curl util-linux jq
            ;;
        fedora)
            dnf install -y $fw_pkgs curl util-linux jq
            ;;
        opensuse-leap|sles)
            zypper install -y $fw_pkgs curl util-linux jq
            ;;
        arch)
            pacman -Sy --noconfirm $fw_pkgs curl util-linux jq
            ;;
        alpine)
            apk add $fw_pkgs curl jq util-linux
            ;;
        *)
            echo "Unsupported Linux distribution: $DISTRO_ID"
            echo "Please install the required packages manually: $fw_pkgs curl jq util-linux"
            exit 1
            ;;
    esac

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

# Firewall backend (nftables or iptables)
BACKEND="$BACKEND"

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

# Set Names (blacklists - hash sets for individual IPs)
NFT_SET_NAME_V4="qfeeds_blacklist_v4"
NFT_SET_NAME_V6="qfeeds_blacklist_v6"

# Set Names (blacklists - interval/net sets for CIDRs)
NFT_NET_SET_NAME_V4="qfeeds_blacklist_v4_nets"
NFT_NET_SET_NAME_V6="qfeeds_blacklist_v6_nets"

# Set Names (whitelists)
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
# Q-Feeds Blocklist Update Script (nftables / iptables+ipset)
# =============================================================================
# This script fetches the latest threat intelligence data from Q-Feeds and
# updates firewall rules to block malicious IP addresses (both IPv4 and IPv6).
# Supports nftables and iptables+ipset backends (auto-detected at install).
# =============================================================================

export PATH=$PATH:/sbin:/usr/sbin
set -e
HTTP_USER_AGENT="Q-Feeds_NFtables-IPtables/1.0"

# Default log location so early LOG() calls (lock failure, cleanup trap) work
# before the configuration file is sourced. Overridden by the config if set.
LOG_FILE="${LOG_FILE:-/var/log/qfeeds_blocklist.log}"

LOG() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $1" | tee -a "$LOG_FILE"
}

cleanup() {
    rm -f "$TEMP_IPV4" "$TEMP_IPV6" "$BATCH_FILE"
    LOG "Cleaned up temporary files."
}

trap cleanup EXIT

# Acquire lock to prevent multiple instances
exec 200>/var/lock/qfeeds_blocklist.lock
flock -n 200 || { LOG "Another instance is running. Exiting."; exit 1; }

check_dependencies() {
    local missing=0
    local deps="curl flock jq"
    if [ "$BACKEND" = "nftables" ]; then
        deps="nft $deps"
    else
        deps="iptables ipset $deps"
    fi
    for cmd in $deps; do
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

should_run_now() {
    LOG "Checking cached license schedule at $LICENSE_CACHE_FILE"

    if [ ! -f "$LICENSE_CACHE_FILE" ]; then
        LOG "No cached license index found. Downloading initial licenses.php response."
        if ! refresh_license_cache; then
            LOG "Warning: Could not initialize license cache, proceeding with update anyway."
            return 0
        fi
    fi

    # Extract next_update for the configured FEED_TYPE from the cached index.
    local next_update
    next_update=$(jq -r --arg ft "$FEED_TYPE" '
        .feeds[] | select(.feed_type == $ft and .licensed == true) | .next_update
    ' "$LICENSE_CACHE_FILE")

    if [ -z "$next_update" ] || [ "$next_update" = "null" ]; then
        LOG "Warning: No cached next_update found for feed_type=$FEED_TYPE, proceeding."
        return 0
    fi

    local now_epoch next_epoch
    now_epoch=$(date -u +%s)
    # GNU date uses -d; BSD/macOS date uses -j -f. Fall back so non-GNU systems
    # can still parse the cached "YYYY-MM-DD HH:MM:SS" schedule.
    next_epoch=$(date -u -d "$next_update" +%s 2>/dev/null \
        || date -u -j -f "%Y-%m-%d %H:%M:%S" "$next_update" +%s 2>/dev/null \
        || echo "")

    if [ -z "$next_epoch" ]; then
        LOG "Warning: Could not parse cached next_update='$next_update', refreshing cache and proceeding."
        rm -f "$LICENSE_CACHE_FILE"
        return 0
    fi

    if [ "$now_epoch" -lt "$next_epoch" ]; then
        LOG "Not time yet. Cached next update scheduled at $next_update (UTC). Skipping this run."
        exit 0
    fi

    LOG "Cached license schedule allows update (now >= $next_update). Continuing."
}

refresh_license_cache() {
    LICENSES_URL="https://api.qfeeds.com/licenses.php?api_token=${API_TOKEN}"
    LOG "Refreshing license cache from $LICENSES_URL"

    local tmp_licenses http_status
    tmp_licenses=$(mktemp /tmp/qfeeds_licenses.XXXXXX)
    http_status=$(curl -A "$HTTP_USER_AGENT" -s -w "%{http_code}" -m 60 -o "$tmp_licenses" "$LICENSES_URL")

    if [ "$http_status" -ne 200 ]; then
        LOG "Warning: licenses.php returned HTTP $http_status, keeping existing cached schedule."
        rm -f "$tmp_licenses"
        return 1
    fi

    if ! jq -e '.feeds' "$tmp_licenses" >/dev/null 2>&1; then
        LOG "Warning: licenses.php returned invalid JSON, keeping existing cached schedule."
        rm -f "$tmp_licenses"
        return 1
    fi

    mv "$tmp_licenses" "$LICENSE_CACHE_FILE"
    chmod 600 "$LICENSE_CACHE_FILE" 2>/dev/null || true
    LOG "License cache refreshed."
    return 0
}

setup_nft() {
    nft add table ip qfeeds 2>/dev/null || true
    nft list set ip qfeeds "$NFT_SET_NAME_V4" &>/dev/null || \
        nft add set ip qfeeds "$NFT_SET_NAME_V4" { type ipv4_addr\; }
    nft list set ip qfeeds "$NFT_NET_SET_NAME_V4" &>/dev/null || \
        nft add set ip qfeeds "$NFT_NET_SET_NAME_V4" { type ipv4_addr\; flags interval\; auto-merge\; }
    nft list set ip qfeeds "$NFT_WHITELIST_SET_NAME_V4" &>/dev/null || \
        nft add set ip qfeeds "$NFT_WHITELIST_SET_NAME_V4" { type ipv4_addr\; flags interval\; auto-merge\; }
    LOG "IPv4 table and sets ready."

    nft add table ip6 qfeeds 2>/dev/null || true
    nft list set ip6 qfeeds "$NFT_SET_NAME_V6" &>/dev/null || \
        nft add set ip6 qfeeds "$NFT_SET_NAME_V6" { type ipv6_addr\; }
    nft list set ip6 qfeeds "$NFT_NET_SET_NAME_V6" &>/dev/null || \
        nft add set ip6 qfeeds "$NFT_NET_SET_NAME_V6" { type ipv6_addr\; flags interval\; auto-merge\; }
    nft list set ip6 qfeeds "$NFT_WHITELIST_SET_NAME_V6" &>/dev/null || \
        nft add set ip6 qfeeds "$NFT_WHITELIST_SET_NAME_V6" { type ipv6_addr\; flags interval\; auto-merge\; }
    LOG "IPv6 table and sets ready."

    if [ "$BLOCK_INCOMING" = "yes" ]; then
        if ! nft list chain ip qfeeds input-chain &>/dev/null; then
            nft add chain ip qfeeds input-chain { type filter hook input priority 0\; policy accept\; }
            LOG "Created IPv4 input-chain in qfeeds table."
        fi
        nft list chain ip qfeeds input-chain | grep -q "ip saddr @$NFT_WHITELIST_SET_NAME_V4 accept" || \
            nft add rule ip qfeeds input-chain ip saddr @${NFT_WHITELIST_SET_NAME_V4} accept
        nft list chain ip qfeeds input-chain | grep -q "ip saddr @$NFT_SET_NAME_V4 drop" || \
            nft add rule ip qfeeds input-chain ip saddr @${NFT_SET_NAME_V4} drop
        nft list chain ip qfeeds input-chain | grep -q "ip saddr @$NFT_NET_SET_NAME_V4 drop" || \
            nft add rule ip qfeeds input-chain ip saddr @${NFT_NET_SET_NAME_V4} drop
    fi

    if [ "$BLOCK_OUTGOING" = "yes" ]; then
        if ! nft list chain ip qfeeds output-chain &>/dev/null; then
            nft add chain ip qfeeds output-chain { type filter hook output priority 0\; policy accept\; }
            LOG "Created IPv4 output-chain in qfeeds table."
        fi
        nft list chain ip qfeeds output-chain | grep -q "ip daddr @$NFT_WHITELIST_SET_NAME_V4 accept" || \
            nft add rule ip qfeeds output-chain ip daddr @${NFT_WHITELIST_SET_NAME_V4} accept
        nft list chain ip qfeeds output-chain | grep -q "ip daddr @$NFT_SET_NAME_V4 drop" || \
            nft add rule ip qfeeds output-chain ip daddr @${NFT_SET_NAME_V4} drop
        nft list chain ip qfeeds output-chain | grep -q "ip daddr @$NFT_NET_SET_NAME_V4 drop" || \
            nft add rule ip qfeeds output-chain ip daddr @${NFT_NET_SET_NAME_V4} drop
    fi

    if [ "$BLOCK_INCOMING" = "yes" ]; then
        if ! nft list chain ip6 qfeeds input-chain &>/dev/null; then
            nft add chain ip6 qfeeds input-chain { type filter hook input priority 0\; policy accept\; }
            LOG "Created IPv6 input-chain in qfeeds table."
        fi
        nft list chain ip6 qfeeds input-chain | grep -q "ip6 saddr @$NFT_WHITELIST_SET_NAME_V6 accept" || \
            nft add rule ip6 qfeeds input-chain ip6 saddr @${NFT_WHITELIST_SET_NAME_V6} accept
        nft list chain ip6 qfeeds input-chain | grep -q "ip6 saddr @$NFT_SET_NAME_V6 drop" || \
            nft add rule ip6 qfeeds input-chain ip6 saddr @${NFT_SET_NAME_V6} drop
        nft list chain ip6 qfeeds input-chain | grep -q "ip6 saddr @$NFT_NET_SET_NAME_V6 drop" || \
            nft add rule ip6 qfeeds input-chain ip6 saddr @${NFT_NET_SET_NAME_V6} drop
    fi

    if [ "$BLOCK_OUTGOING" = "yes" ]; then
        if ! nft list chain ip6 qfeeds output-chain &>/dev/null; then
            nft add chain ip6 qfeeds output-chain { type filter hook output priority 0\; policy accept\; }
            LOG "Created IPv6 output-chain in qfeeds table."
        fi
        nft list chain ip6 qfeeds output-chain | grep -q "ip6 daddr @$NFT_WHITELIST_SET_NAME_V6 accept" || \
            nft add rule ip6 qfeeds output-chain ip6 daddr @${NFT_WHITELIST_SET_NAME_V6} accept
        nft list chain ip6 qfeeds output-chain | grep -q "ip6 daddr @$NFT_SET_NAME_V6 drop" || \
            nft add rule ip6 qfeeds output-chain ip6 daddr @${NFT_SET_NAME_V6} drop
        nft list chain ip6 qfeeds output-chain | grep -q "ip6 daddr @$NFT_NET_SET_NAME_V6 drop" || \
            nft add rule ip6 qfeeds output-chain ip6 daddr @${NFT_NET_SET_NAME_V6} drop
    fi
}

setup_iptables() {
    # Create ipset sets: hash:ip for individual IPs, hash:net for CIDRs/whitelists
    ipset create "$NFT_SET_NAME_V4" hash:ip hashsize 131072 maxelem 1000000 -exist
    ipset create "$NFT_NET_SET_NAME_V4" hash:net maxelem 65536 -exist
    ipset create "$NFT_WHITELIST_SET_NAME_V4" hash:net maxelem 65536 -exist
    LOG "IPv4 ipsets ready."

    ipset create "$NFT_SET_NAME_V6" hash:ip family inet6 hashsize 16384 maxelem 200000 -exist
    ipset create "$NFT_NET_SET_NAME_V6" hash:net family inet6 maxelem 65536 -exist
    ipset create "$NFT_WHITELIST_SET_NAME_V6" hash:net family inet6 maxelem 65536 -exist
    LOG "IPv6 ipsets ready."

    # Remove legacy directly-inserted rules from older versions of this script.
    # They were added straight onto INPUT/OUTPUT with -I in an order that left
    # the whitelist ACCEPT *below* the DROP rules (whitelist ineffective). We now
    # use a dedicated chain instead; strip the old rules so installs self-correct.
    remove_legacy_ipt_rules() {
        local ipt_cmd="$1" hook="$2" dir="$3" wl="$4" ip_set="$5" net_set="$6"
        while "$ipt_cmd" -D "$hook" -m set --match-set "$wl" "$dir" -j ACCEPT -m comment --comment "qfeeds" 2>/dev/null; do :; done
        while "$ipt_cmd" -D "$hook" -m set --match-set "$ip_set" "$dir" -j DROP -m comment --comment "qfeeds" 2>/dev/null; do :; done
        while "$ipt_cmd" -D "$hook" -m set --match-set "$net_set" "$dir" -j DROP -m comment --comment "qfeeds" 2>/dev/null; do :; done
    }

    # Build (or rebuild) a dedicated qfeeds chain in a deterministic order:
    # whitelist ACCEPT first, then the blacklist DROP rules. The hook (INPUT or
    # OUTPUT) jumps to this chain. Rebuilding each run guarantees correct order
    # and self-corrects any previously broken ordering.
    build_ipt_chain() {
        local ipt_cmd="$1" chain="$2" hook="$3" dir="$4" wl="$5" ip_set="$6" net_set="$7"
        "$ipt_cmd" -N "$chain" 2>/dev/null || true
        "$ipt_cmd" -F "$chain"
        "$ipt_cmd" -A "$chain" -m set --match-set "$wl" "$dir" -j ACCEPT -m comment --comment "qfeeds"
        "$ipt_cmd" -A "$chain" -m set --match-set "$ip_set" "$dir" -j DROP -m comment --comment "qfeeds"
        "$ipt_cmd" -A "$chain" -m set --match-set "$net_set" "$dir" -j DROP -m comment --comment "qfeeds"
        # Ensure the hook jumps to our chain exactly once (insert at the top).
        "$ipt_cmd" -C "$hook" -j "$chain" -m comment --comment "qfeeds" 2>/dev/null || \
            "$ipt_cmd" -I "$hook" -j "$chain" -m comment --comment "qfeeds"
    }

    if [ "$BLOCK_INCOMING" = "yes" ]; then
        remove_legacy_ipt_rules iptables INPUT src "$NFT_WHITELIST_SET_NAME_V4" "$NFT_SET_NAME_V4" "$NFT_NET_SET_NAME_V4"
        build_ipt_chain iptables QFEEDS_INPUT INPUT src "$NFT_WHITELIST_SET_NAME_V4" "$NFT_SET_NAME_V4" "$NFT_NET_SET_NAME_V4"
        LOG "IPv4 INPUT chain ready (whitelist precedes blacklist)."

        remove_legacy_ipt_rules ip6tables INPUT src "$NFT_WHITELIST_SET_NAME_V6" "$NFT_SET_NAME_V6" "$NFT_NET_SET_NAME_V6"
        build_ipt_chain ip6tables QFEEDS_INPUT INPUT src "$NFT_WHITELIST_SET_NAME_V6" "$NFT_SET_NAME_V6" "$NFT_NET_SET_NAME_V6"
        LOG "IPv6 INPUT chain ready (whitelist precedes blacklist)."
    fi

    if [ "$BLOCK_OUTGOING" = "yes" ]; then
        remove_legacy_ipt_rules iptables OUTPUT dst "$NFT_WHITELIST_SET_NAME_V4" "$NFT_SET_NAME_V4" "$NFT_NET_SET_NAME_V4"
        build_ipt_chain iptables QFEEDS_OUTPUT OUTPUT dst "$NFT_WHITELIST_SET_NAME_V4" "$NFT_SET_NAME_V4" "$NFT_NET_SET_NAME_V4"
        LOG "IPv4 OUTPUT chain ready (whitelist precedes blacklist)."

        remove_legacy_ipt_rules ip6tables OUTPUT dst "$NFT_WHITELIST_SET_NAME_V6" "$NFT_SET_NAME_V6" "$NFT_NET_SET_NAME_V6"
        build_ipt_chain ip6tables QFEEDS_OUTPUT OUTPUT dst "$NFT_WHITELIST_SET_NAME_V6" "$NFT_SET_NAME_V6" "$NFT_NET_SET_NAME_V6"
        LOG "IPv6 OUTPUT chain ready (whitelist precedes blacklist)."
    fi
}

setup_firewall() {
    if [ "$BACKEND" = "nftables" ]; then
        setup_nft
    else
        setup_iptables
    fi
}

# ================================
# Feed Fetching & Sync Functions
# ================================

fetch_feed() {
    local url="$1"
    local outfile="$2"
    local desc="$3"
    local allow_empty="${4:-0}"
    LOG "Fetching $desc..."
    local http_status
    http_status=$(curl -A "$HTTP_USER_AGENT" -s -w "%{http_code}" -m 300 -o "$outfile" "$url")
    if [ "$http_status" -ne 200 ]; then
        LOG "Error: Failed to fetch $desc. HTTP $http_status"
        return 1
    fi
    if [ ! -s "$outfile" ]; then
        LOG "Warning: $desc response is empty."
        if [ "$allow_empty" = "1" ]; then
            LOG "$desc returned no entries; treating as no changes."
            : > "$outfile"
            return 0
        fi
        return 1
    fi
    local count
    count=$(wc -l < "$outfile")
    LOG "Fetched $desc: $count lines."
    return 0
}

build_feed_url() {
    local ipv6_param="$1"
    local diff_param="$2"
    local url="https://api.qfeeds.com/api?feed_type=${FEED_TYPE}&api_token=${API_TOKEN}&ipv6=${ipv6_param}"
    if [ -n "$LIMIT" ] && [ "$LIMIT" -gt 0 ] 2>/dev/null; then
        url="${url}&limit=${LIMIT}"
    fi
    if [ -n "$diff_param" ]; then
        url="${url}&diff=${diff_param}"
    fi
    echo "$url"
}

batch_load_set() {
    local infile="$1"
    local family="$2"
    local ip_setname="$3"
    local net_setname="$4"

    if [ "$BACKEND" = "nftables" ]; then
        grep -v '^[[:space:]]*$' "$infile" | grep -v '^#' | sort -u | \
        awk -v fam="$family" -v ipsn="$ip_setname" -v netsn="$net_setname" '
        BEGIN { nip=0; ipbuf=""; nnet=0; netbuf="" }
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length($0) == 0) next
            if (index($0, "/") > 0) {
                if (nnet > 0) netbuf = netbuf ", "
                netbuf = netbuf $0
                nnet++
                if (nnet >= 200) {
                    print "add element " fam " qfeeds " netsn " { " netbuf " }"
                    nnet=0; netbuf=""
                }
            } else {
                if (nip > 0) ipbuf = ipbuf ", "
                ipbuf = ipbuf $0
                nip++
                if (nip >= 2000) {
                    print "add element " fam " qfeeds " ipsn " { " ipbuf " }"
                    nip=0; ipbuf=""
                }
            }
        }
        END {
            if (nip > 0) print "add element " fam " qfeeds " ipsn " { " ipbuf " }"
            if (nnet > 0) print "add element " fam " qfeeds " netsn " { " netbuf " }"
        }
        '
    else
        # ipset restore format: one "add <setname> <ip>" per line
        grep -v '^[[:space:]]*$' "$infile" | grep -v '^#' | sort -u | \
        awk -v ipsn="$ip_setname" -v netsn="$net_setname" '
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length($0) == 0) next
            if (index($0, "/") > 0) {
                print "add " netsn " " $0
            } else {
                print "add " ipsn " " $0
            }
        }
        '
    fi
}

batch_apply() {
    local batchfile="$1"

    if [ "$BACKEND" = "nftables" ]; then
        if nft -f "$batchfile" 2>>"$LOG_FILE"; then
            return 0
        fi

        LOG "Batch nft -f failed. Falling back to per-command execution..."

        apply_nft_delete_command() {
            local cmd="$1"
            local count="$2"
            local total="$3"
            local prefix elements raw_elem elem nft_error
            local skipped=0

            if [[ "$cmd" != delete\ element* ]] || [[ "$cmd" != *"{"*"}"* ]]; then
                return 1
            fi

            prefix="${cmd%%\{*}"
            elements="${cmd#*\{}"
            elements="${elements%\}*}"

            IFS=',' read -r -a delete_elements <<< "$elements"
            for raw_elem in "${delete_elements[@]}"; do
                elem="$raw_elem"
                elem="${elem#"${elem%%[![:space:]]*}"}"
                elem="${elem%"${elem##*[![:space:]]}"}"
                [ -z "$elem" ] && continue

                if ! nft_error=$(nft "${prefix}{ ${elem} }" 2>&1); then
                    if [[ "$nft_error" == *"No such file or directory"* ]]; then
                        skipped=$((skipped + 1))
                        continue
                    fi
                    [ -n "$nft_error" ] && printf '%s\n' "$nft_error" >> "$LOG_FILE"
                    LOG "Error on delete command $count/$total for element '$elem': ${nft_error%%$'\n'*}"
                    return 1
                fi
                [ -n "$nft_error" ] && printf '%s\n' "$nft_error" >> "$LOG_FILE"
            done

            if [ "$skipped" -gt 0 ]; then
                LOG "Skipped $skipped missing delete target(s) on command $count/$total."
            fi
            return 0
        }

        local total failed=0 count=0 nft_error
        total=$(wc -l < "$batchfile")
        while IFS= read -r cmd; do
            count=$((count + 1))
            if ! nft_error=$(nft "$cmd" 2>&1); then
                if [[ "$cmd" == delete\ element* ]] && [[ "$nft_error" == *"No such file or directory"* ]]; then
                    if apply_nft_delete_command "$cmd" "$count" "$total"; then
                        continue
                    fi
                fi
                [ -n "$nft_error" ] && printf '%s\n' "$nft_error" >> "$LOG_FILE"
                LOG "Error on command $count/$total: ${cmd:0:80}..."
                failed=1
                break
            fi
            [ -n "$nft_error" ] && printf '%s\n' "$nft_error" >> "$LOG_FILE"
            if [ $((count % 50)) -eq 0 ]; then
                LOG "  Progress: $count/$total commands applied..."
            fi
        done < "$batchfile"
        return $failed
    else
        # ipset restore: single call processes entire file, -exist ignores duplicates
        if ipset restore -exist < "$batchfile" 2>>"$LOG_FILE"; then
            return 0
        fi
        LOG "ipset restore failed. Check log for details."
        return 1
    fi
}

# Flush the ip + net sets for a single address family.
flush_family_sets() {
    local family="$1"   # ip | ip6
    local ip_setname="$2"
    local net_setname="$3"
    if [ "$BACKEND" = "nftables" ]; then
        nft flush set "$family" qfeeds "$ip_setname" 2>/dev/null || true
        nft flush set "$family" qfeeds "$net_setname" 2>/dev/null || true
    else
        ipset flush "$ip_setname" 2>/dev/null || true
        ipset flush "$net_setname" 2>/dev/null || true
    fi
}

# Full sync for a single address family. Fetches and validates the feed into a
# batch file BEFORE flushing the live set, so a failed fetch/parse can never
# leave the firewall with an empty (unprotected) set. Returns 0 only when the
# set was successfully rebuilt with data.
full_sync_family() {
    local family="$1"        # ip | ip6
    local ipv6_param="$2"    # 0 | only
    local ip_setname="$3"
    local net_setname="$4"
    local tmpfile="$5"
    local desc="$6"

    local url
    url=$(build_feed_url "$ipv6_param" "")
    if ! fetch_feed "$url" "$tmpfile" "$desc"; then
        LOG "Error: $desc fetch failed; keeping existing set (not flushed)."
        return 1
    fi

    batch_load_set "$tmpfile" "$family" "$ip_setname" "$net_setname" > "$BATCH_FILE"
    if [ ! -s "$BATCH_FILE" ]; then
        LOG "Warning: $desc produced no loadable entries; keeping existing set (not flushed)."
        : > "$BATCH_FILE"
        return 1
    fi

    local batch_lines
    batch_lines=$(wc -l < "$BATCH_FILE")
    LOG "Loading $desc: $batch_lines commands..."

    # Data is validated and in hand: now it is safe to flush + reload.
    flush_family_sets "$family" "$ip_setname" "$net_setname"
    if batch_apply "$BATCH_FILE"; then
        LOG "$desc loaded successfully."
        : > "$BATCH_FILE"
        return 0
    fi

    LOG "Error: batch apply failed for $desc."
    : > "$BATCH_FILE"
    return 1
}

apply_full_sync() {
    LOG "Starting full sync..."
    local v4_ok=0 v6_ok=0

    if full_sync_family "ip" "0" "$NFT_SET_NAME_V4" "$NFT_NET_SET_NAME_V4" "$TEMP_IPV4" "IPv4 feed"; then
        v4_ok=1
    fi

    if full_sync_family "ip6" "only" "$NFT_SET_NAME_V6" "$NFT_NET_SET_NAME_V6" "$TEMP_IPV6" "IPv6 feed"; then
        v6_ok=1
    fi

    if [ "$v4_ok" -eq 1 ] && [ "$v6_ok" -eq 1 ]; then
        touch "$STATE_FILE"
        LOG "Full sync completed (IPv4 + IPv6)."
        FEED_PULL_OK=1
    else
        # Do NOT advance the state file on a partial/failed full sync, and remove
        # it so the next run retries a full sync instead of diffing onto a set
        # that may be partially loaded or stale.
        rm -f "$STATE_FILE" 2>/dev/null || true
        if [ "$v4_ok" -eq 1 ] || [ "$v6_ok" -eq 1 ]; then
            LOG "Error: Full sync only partially succeeded (v4_ok=$v4_ok v6_ok=$v6_ok). State file cleared; next run will retry a full sync."
        else
            LOG "Error: Full sync failed — no feeds were loaded. State file cleared; next run will retry a full sync."
        fi
        FEED_PULL_OK=0
    fi
}

generate_diff_batch() {
    local infile="$1"
    local family="$2"
    local ip_setname="$3"
    local net_setname="$4"

    if [ "$BACKEND" = "nftables" ]; then
        awk -v fam="$family" -v ipsn="$ip_setname" -v netsn="$net_setname" '
        BEGIN { nia=0;iab=""; nna=0;nab="" }
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length($0)==0||substr($0,1,1)=="#") next
            p=substr($0,1,1); r=substr($0,2); gsub(/^[[:space:]]+/,"",r)
            cidr=(index(r,"/")>0)
            if (p=="+") {
                if (cidr) {
                    if(nna>0) nab=nab", "; nab=nab r; nna++
                    if(nna>=200){print "add element "fam" qfeeds "netsn" { "nab" }";nna=0;nab=""}
                } else {
                    if(nia>0) iab=iab", "; iab=iab r; nia++
                    if(nia>=2000){print "add element "fam" qfeeds "ipsn" { "iab" }";nia=0;iab=""}
                }
            } else if (p=="-") {
                if (cidr) {
                    print "delete element "fam" qfeeds "netsn" { "r" }"
                } else {
                    print "delete element "fam" qfeeds "ipsn" { "r" }"
                }
            }
        }
        END {
            if(nia>0) print "add element "fam" qfeeds "ipsn" { "iab" }"
            if(nna>0) print "add element "fam" qfeeds "netsn" { "nab" }"
        }
        ' "$infile"
    else
        # ipset restore format: "add/del <setname> <ip>"
        awk -v ipsn="$ip_setname" -v netsn="$net_setname" '
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length($0)==0||substr($0,1,1)=="#") next
            p=substr($0,1,1); r=substr($0,2); gsub(/^[[:space:]]+/,"",r)
            cidr=(index(r,"/")>0)
            if (p=="+") {
                if (cidr) { print "add " netsn " " r }
                else      { print "add " ipsn " " r }
            } else if (p=="-") {
                if (cidr) { print "del " netsn " " r }
                else      { print "del " ipsn " " r }
            }
        }
        ' "$infile"
    fi
}

apply_diff_sync() {
    LOG "Starting diff sync..."

    local had_changes=0

    local url_v4
    url_v4=$(build_feed_url "0" "yes")
    # allow_empty=1: an empty diff means "no changes since last pull", which is
    # normal during quiet cycles and must NOT be treated as a fetch failure
    # (otherwise every quiet cycle would trigger a full ~600k flush+reload).
    if fetch_feed "$url_v4" "$TEMP_IPV4" "IPv4 diff" "1"; then
        generate_diff_batch "$TEMP_IPV4" "ip" "$NFT_SET_NAME_V4" "$NFT_NET_SET_NAME_V4" > "$BATCH_FILE"

        if [ -s "$BATCH_FILE" ]; then
            if batch_apply "$BATCH_FILE"; then
                LOG "IPv4 diff applied."
                had_changes=1
            else
                LOG "Error: diff apply failed for IPv4. Falling back to full sync."
                apply_full_sync
                return
            fi
        else
            LOG "IPv4 diff: no changes."
        fi
        : > "$BATCH_FILE"
    else
        LOG "IPv4 diff fetch failed. Falling back to full sync."
        apply_full_sync
        return
    fi

    local url_v6
    url_v6=$(build_feed_url "only" "yes")
    if fetch_feed "$url_v6" "$TEMP_IPV6" "IPv6 diff" "1"; then
        generate_diff_batch "$TEMP_IPV6" "ip6" "$NFT_SET_NAME_V6" "$NFT_NET_SET_NAME_V6" > "$BATCH_FILE"

        if [ -s "$BATCH_FILE" ]; then
            if batch_apply "$BATCH_FILE"; then
                LOG "IPv6 diff applied."
                had_changes=1
            else
                LOG "Error: diff apply failed for IPv6. Falling back to full sync."
                apply_full_sync
                return
            fi
        else
            LOG "IPv6 diff: no changes (empty diff response accepted)."
        fi
        : > "$BATCH_FILE"
    else
        LOG "IPv6 diff fetch failed. Falling back to full sync."
        apply_full_sync
        return
    fi

    touch "$STATE_FILE"
    FEED_PULL_OK=1
    if [ "$had_changes" -eq 1 ]; then
        LOG "Diff sync completed with changes."
    else
        LOG "Diff sync completed (no changes in this cycle)."
    fi
}

update_whitelist_sets() {
    LOG "Updating whitelist sets (if configured)."

    if [ "$BACKEND" = "nftables" ]; then
        nft flush set ip qfeeds "$NFT_WHITELIST_SET_NAME_V4" 2>/dev/null || true
        nft flush set ip6 qfeeds "$NFT_WHITELIST_SET_NAME_V6" 2>/dev/null || true
    else
        ipset flush "$NFT_WHITELIST_SET_NAME_V4" 2>/dev/null || true
        ipset flush "$NFT_WHITELIST_SET_NAME_V6" 2>/dev/null || true
    fi

    if [ -n "$WHITELIST_V4" ]; then
        echo "$WHITELIST_V4" | tr ',' '\n' | while IFS= read -r ip; do
            ip_trimmed=$(echo "$ip" | xargs)
            [ -z "$ip_trimmed" ] && continue
            if [ "$BACKEND" = "nftables" ]; then
                nft add element ip qfeeds "$NFT_WHITELIST_SET_NAME_V4" { "$ip_trimmed" }
            else
                ipset add "$NFT_WHITELIST_SET_NAME_V4" "$ip_trimmed" -exist
            fi
        done
        LOG "IPv4 whitelist set $NFT_WHITELIST_SET_NAME_V4 updated."
    else
        LOG "No IPv4 whitelist configured."
    fi

    if [ -n "$WHITELIST_V6" ]; then
        echo "$WHITELIST_V6" | tr ',' '\n' | while IFS= read -r ip; do
            ip_trimmed=$(echo "$ip" | xargs)
            [ -z "$ip_trimmed" ] && continue
            if [ "$BACKEND" = "nftables" ]; then
                nft add element ip6 qfeeds "$NFT_WHITELIST_SET_NAME_V6" { "$ip_trimmed" }
            else
                ipset add "$NFT_WHITELIST_SET_NAME_V6" "$ip_trimmed" -exist
            fi
        done
        LOG "IPv6 whitelist set $NFT_WHITELIST_SET_NAME_V6 updated."
    else
        LOG "No IPv6 whitelist configured."
    fi
}

save_rules() {
    if [ "$BACKEND" = "nftables" ]; then
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
            LOG "Saved nftables rules using netfilter-persistent."
        else
            # netfilter-persistent is not available: persist the full ruleset
            # ourselves so the blocklist survives a reboot. nft list ruleset
            # dumps ALL currently loaded tables, so this preserves any other
            # firewall configuration that is already active.
            if nft list ruleset > /etc/nftables.conf 2>/dev/null; then
                chmod 600 /etc/nftables.conf 2>/dev/null || true
                LOG "WARNING: netfilter-persistent not found. Wrote current ruleset to /etc/nftables.conf so the blocklist persists across reboots."
                if command -v systemctl &>/dev/null; then
                    systemctl enable nftables &>/dev/null || true
                fi
            else
                LOG "WARNING: Could not persist the nftables ruleset. The blocklist will be LOST on reboot. Install netfilter-persistent or enable the nftables service."
            fi
        fi
    else
        ipset save > /etc/ipset.conf 2>/dev/null || true
        LOG "Saved ipset sets to /etc/ipset.conf"
        if command -v iptables-save &>/dev/null; then
            iptables-save > /etc/iptables.rules 2>/dev/null || true
            ip6tables-save > /etc/ip6tables.rules 2>/dev/null || true
            LOG "Saved iptables rules to /etc/iptables.rules and /etc/ip6tables.rules"
        fi
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save 2>/dev/null || true
            LOG "Saved rules using netfilter-persistent."
        fi
    fi
}

# Returns the total number of elements currently loaded across the v4/v6
# blacklist sets (individual IPs + CIDR/net sets). Used to detect a local set
# that has lost its baseline (e.g. after a reboot, manual flush, or a partial
# sync) so we can force a full rebuild instead of diffing onto an empty set.
get_blacklist_count() {
    local total=0 c family setname set_spec

    if [ "$BACKEND" = "nftables" ]; then
        for set_spec in "ip $NFT_SET_NAME_V4" "ip $NFT_NET_SET_NAME_V4" "ip6 $NFT_SET_NAME_V6" "ip6 $NFT_NET_SET_NAME_V6"; do
            family=${set_spec%% *}
            setname=${set_spec#* }
            c=$(nft -j list set "$family" qfeeds "$setname" 2>/dev/null | \
                jq '[.nftables[] | select(.set) | (.set.elem // [] | length)] | add // 0' 2>/dev/null)
            [ -z "$c" ] && c=0
            total=$((total + c))
        done
    else
        for setname in "$NFT_SET_NAME_V4" "$NFT_NET_SET_NAME_V4" "$NFT_SET_NAME_V6" "$NFT_NET_SET_NAME_V6"; do
            c=$(ipset list -t "$setname" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}')
            [ -z "$c" ] && c=0
            total=$((total + c))
        done
    fi

    echo "$total"
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

# Default backend if not set (backwards compatibility with pre-iptables configs)
[ -z "$BACKEND" ] && BACKEND="nftables"

# Default directional options if not set (backwards compatibility)
[ -z "$BLOCK_INCOMING" ] && BLOCK_INCOMING="yes"
[ -z "$BLOCK_OUTGOING" ] && BLOCK_OUTGOING="no"

# Default set names if not set (backwards compatibility)
[ -z "$NFT_SET_NAME_V4" ] && NFT_SET_NAME_V4="qfeeds_blacklist_v4"
[ -z "$NFT_SET_NAME_V6" ] && NFT_SET_NAME_V6="qfeeds_blacklist_v6"
[ -z "$NFT_NET_SET_NAME_V4" ] && NFT_NET_SET_NAME_V4="qfeeds_blacklist_v4_nets"
[ -z "$NFT_NET_SET_NAME_V6" ] && NFT_NET_SET_NAME_V6="qfeeds_blacklist_v6_nets"
[ -z "$NFT_WHITELIST_SET_NAME_V4" ] && NFT_WHITELIST_SET_NAME_V4="qfeeds_whitelist_v4"
[ -z "$NFT_WHITELIST_SET_NAME_V6" ] && NFT_WHITELIST_SET_NAME_V6="qfeeds_whitelist_v6"

STATE_FILE="/etc/qfeeds/.last_sync"
LICENSE_CACHE_FILE="/etc/qfeeds/licenses_index.json"
# Records the element count after the last successful sync. Used to detect a
# local set that has lost its baseline so diff mode does not patch an empty set.
COUNT_FILE="/etc/qfeeds/.last_count"
# Force a periodic full re-sync so any slow diff drift self-heals (seconds).
# Can be overridden in the config file. Default: 24h.
FULL_SYNC_MAX_AGE="${FULL_SYNC_MAX_AGE:-86400}"

TEMP_IPV4=$(mktemp /tmp/qfeeds_ipv4.XXXXXX)
TEMP_IPV6=$(mktemp /tmp/qfeeds_ipv6.XXXXXX)
BATCH_FILE=$(mktemp /tmp/qfeeds_nft_batch.XXXXXX)

check_dependencies
setup_firewall

if [ "$QFEEDS_FORCE_UPDATE" = "1" ]; then
    LOG "Force update requested (QFEEDS_FORCE_UPDATE=1). Skipping license schedule check."
else
    should_run_now
fi

# Determine sync mode: full on first run / force, diff for subsequent runs (malware_ip only)
if [ "$QFEEDS_FORCE_UPDATE" = "1" ] || [ ! -f "$STATE_FILE" ]; then
    SYNC_MODE="full"
elif [ "$FEED_TYPE" = "malware_ip" ]; then
    SYNC_MODE="diff"

    # Defense in depth: force a periodic full re-sync so diff drift self-heals.
    if [ -n "$FULL_SYNC_MAX_AGE" ] && [ "$FULL_SYNC_MAX_AGE" -gt 0 ] 2>/dev/null; then
        state_mtime=$(stat -c %Y "$STATE_FILE" 2>/dev/null || stat -f %m "$STATE_FILE" 2>/dev/null || echo 0)
        state_age=$(( $(date -u +%s) - state_mtime ))
        if [ "$state_age" -ge "$FULL_SYNC_MAX_AGE" ]; then
            LOG "Last sync is ${state_age}s old (>= ${FULL_SYNC_MAX_AGE}s); forcing full sync."
            SYNC_MODE="full"
        fi
    fi

    # Sanity check: never trust diff mode if the local set has lost its baseline
    # (reboot without persistence, manual flush, or a prior partial sync). The
    # STATE_FILE living on disk does NOT prove the in-memory set is populated.
    if [ "$SYNC_MODE" = "diff" ]; then
        live_count=$(get_blacklist_count)
        expected_count=0
        if [ -f "$COUNT_FILE" ]; then
            expected_count=$(tr -d '[:space:]' < "$COUNT_FILE" 2>/dev/null)
        fi
        [ -z "$expected_count" ] && expected_count=0
        if ! [ "$live_count" -ge 0 ] 2>/dev/null; then
            live_count=0
        fi

        if [ "$live_count" -eq 0 ]; then
            LOG "Local blacklist is empty (live count = 0); forcing full sync to rebuild the baseline."
            SYNC_MODE="full"
        elif [ "$expected_count" -gt 0 ] && [ "$live_count" -lt $((expected_count / 2)) ]; then
            LOG "Local blacklist count ($live_count) is far below expected ($expected_count); forcing full sync to rebuild the baseline."
            SYNC_MODE="full"
        else
            LOG "Local blacklist baseline OK (live count = $live_count, expected = $expected_count)."
        fi
    fi
else
    SYNC_MODE="full"
fi

LOG "Sync mode: $SYNC_MODE"

FEED_PULL_OK=0
if [ "$SYNC_MODE" = "diff" ]; then
    apply_diff_sync
else
    apply_full_sync
fi

update_whitelist_sets
save_rules

if [ "${FEED_PULL_OK:-0}" -eq 1 ]; then
    # Record the healthy element count so the next run can detect a lost baseline.
    new_count=$(get_blacklist_count)
    if [ "$new_count" -gt 0 ] 2>/dev/null; then
        echo "$new_count" > "$COUNT_FILE" 2>/dev/null || true
        chmod 600 "$COUNT_FILE" 2>/dev/null || true
        LOG "Recorded blacklist baseline count: $new_count"
    fi
    refresh_license_cache || LOG "Warning: Feed pull succeeded, but failed to refresh local license cache."
    LOG "Feed pull succeeded: Q-Feeds data was downloaded and applied (sync=$SYNC_MODE, feed_type=$FEED_TYPE)."
    LOG "Q-Feeds blocklist update completed successfully (backend: $BACKEND)."
else
    LOG "Feed pull did not succeed: no blocklist data was loaded this run (sync=$SYNC_MODE, feed_type=$FEED_TYPE). See errors above."
    LOG "Q-Feeds run finished (backend: $BACKEND); firewall setup ran but blocklist may be empty or stale."
fi
exit 0
EOF

    chmod 700 "$MAIN_SCRIPT"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    echo "Main script installed at $MAIN_SCRIPT"
}

setup_cron() {
    echo "Setting up cron job..."
    read -rp "Enter cron schedule (e.g., '*/10 * * * *') [default: */10 * * * *]: " CRON_SCHEDULE
    CRON_SCHEDULE=${CRON_SCHEDULE:-"*/10 * * * *"}

    # Remove any existing lines for this script, then add one fresh entry.
    # Use awk instead of grep -v because grep returns exit code 1 when no lines
    # are selected, which interacts badly with "set -e" in this installer.
    local existing_crontab
    existing_crontab="$(crontab -l 2>/dev/null || true)"

    {
        printf '%s\n' "$existing_crontab" | awk -v cmd="$CRON_CMD" '
            index($0, cmd) == 0 { print }
        '
        echo "$CRON_SCHEDULE $CRON_CMD"
    } | crontab -

    # Verify cron entry was written; fail loudly if not.
    if crontab -l 2>/dev/null | grep -Fq "$CRON_CMD"; then
        echo "Cron job added (runs $CRON_CMD on schedule '$CRON_SCHEDULE')."
    else
        echo "Error: Failed to save cron job for $CRON_CMD."
        exit 1
    fi
}

finalize_installation() {
    echo "Finalizing installation..."
    QFEEDS_FORCE_UPDATE=1 "$MAIN_SCRIPT"
    echo "Installation and initial run completed."
}

# ================================
# Main Execution (Installer)
# ================================
echo "Q-Feeds Blocklist Installer (nftables / iptables+ipset)"

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

accept_terms
detect_distro
echo "Detected Linux distribution: $DISTRO_ID $DISTRO_VERSION"

detect_firewall_backend
install_dependencies
configure_script
install_main_script
setup_cron
finalize_installation

echo "Q-Feeds Blocklist setup is complete! (backend: $BACKEND)"
exit 0