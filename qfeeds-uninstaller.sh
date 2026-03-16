#!/bin/bash
# =============================================================================
# Q-Feeds Blocklist Uninstaller Script (nftables / iptables+ipset)
# =============================================================================
# This script removes the Q-Feeds Blocklist from your system, including
# configuration files, cron jobs, firewall rules/sets, and logs.
#
# It does NOT remove any system packages or dependencies that were installed.
# =============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Error: This uninstaller must be run as root."
    exit 1
fi

echo "Q-Feeds Blocklist Uninstaller (nftables / iptables+ipset)"

read -rp "Are you sure you want to uninstall the Q-Feeds Blocklist? (yes/no): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Uninstallation aborted."
    exit 0
fi

# Load configuration
CONFIG_FILE="/etc/qfeeds/qfeeds_config.conf"
BACKEND=""
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Configuration file not found at $CONFIG_FILE"
    echo "Will attempt cleanup for both nftables and iptables backends."
    NFT_SET_NAME_V4="qfeeds_blacklist_v4"
    NFT_SET_NAME_V6="qfeeds_blacklist_v6"
    NFT_NET_SET_NAME_V4="qfeeds_blacklist_v4_nets"
    NFT_NET_SET_NAME_V6="qfeeds_blacklist_v6_nets"
    NFT_WHITELIST_SET_NAME_V4="qfeeds_whitelist_v4"
    NFT_WHITELIST_SET_NAME_V6="qfeeds_whitelist_v6"
    LOG_FILE="/var/log/qfeeds_blocklist.log"
fi

# Remove cron job
echo "Removing cron job..."
CRON_CMD="/usr/local/bin/update_qfeeds_blocklist.sh"
(crontab -l 2>/dev/null | grep -v "$CRON_CMD") | crontab -
echo "Cron job removed."

# -----------------------------------------------------------------------------
# Remove firewall rules
# -----------------------------------------------------------------------------
remove_nftables() {
    echo "Removing nftables rules..."
    if command -v nft &>/dev/null; then
        if nft list table ip qfeeds &>/dev/null; then
            nft delete table ip qfeeds
            echo "Deleted IPv4 table 'qfeeds' (including all chains, rules, and sets)."
        else
            echo "No IPv4 nftable 'qfeeds' found."
        fi

        if nft list table ip6 qfeeds &>/dev/null; then
            nft delete table ip6 qfeeds
            echo "Deleted IPv6 table 'qfeeds' (including all chains, rules, and sets)."
        else
            echo "No IPv6 nftable 'qfeeds' found."
        fi
    else
        echo "nft command not found, skipping nftables cleanup."
    fi
}

remove_iptables() {
    echo "Removing iptables/ipset rules..."

    # Delete by line number: list rules, find "qfeeds" comment lines,
    # delete first match, repeat (re-list each time since numbers shift)
    ipt_remove_qfeeds_rules() {
        local ipt_cmd="$1" chain="$2"
        while true; do
            local num
            num=$("$ipt_cmd" -L "$chain" --line-numbers -n 2>/dev/null \
                  | grep 'qfeeds' | head -1 | awk '{print $1}')
            [ -z "$num" ] && break
            "$ipt_cmd" -D "$chain" "$num"
        done
    }

    if command -v iptables &>/dev/null; then
        ipt_remove_qfeeds_rules iptables INPUT
        ipt_remove_qfeeds_rules iptables OUTPUT
        echo "Removed all IPv4 iptables rules with qfeeds comment."
    fi

    if command -v ip6tables &>/dev/null; then
        ipt_remove_qfeeds_rules ip6tables INPUT
        ipt_remove_qfeeds_rules ip6tables OUTPUT
        echo "Removed all IPv6 ip6tables rules with qfeeds comment."
    fi

    if command -v ipset &>/dev/null; then
        local sets=(
            "$NFT_SET_NAME_V4" "$NFT_NET_SET_NAME_V4" "$NFT_WHITELIST_SET_NAME_V4"
            "$NFT_SET_NAME_V6" "$NFT_NET_SET_NAME_V6" "$NFT_WHITELIST_SET_NAME_V6"
        )
        for s in "${sets[@]}"; do
            if ipset list "$s" &>/dev/null; then
                ipset destroy "$s"
                echo "Destroyed ipset '$s'."
            fi
        done
    else
        echo "ipset command not found, skipping ipset cleanup."
    fi
}

if [ "$BACKEND" = "iptables" ]; then
    remove_iptables
elif [ "$BACKEND" = "nftables" ]; then
    remove_nftables
else
    # No config or unknown backend — try both
    remove_nftables
    remove_iptables
fi

# Save firewall state after removal
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save 2>/dev/null || true
    echo "Saved firewall state using netfilter-persistent."
fi
if [ "$BACKEND" = "iptables" ] || [ -z "$BACKEND" ]; then
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables.rules 2>/dev/null || true
        ip6tables-save > /etc/ip6tables.rules 2>/dev/null || true
    fi
    if command -v ipset &>/dev/null; then
        ipset save > /etc/ipset.conf 2>/dev/null || true
    fi
fi

# -----------------------------------------------------------------------------
# Remove main script
# -----------------------------------------------------------------------------
echo "Removing main script..."
if [ -f "/usr/local/bin/update_qfeeds_blocklist.sh" ]; then
    rm -f "/usr/local/bin/update_qfeeds_blocklist.sh"
    echo "Main script removed."
else
    echo "Main script not found."
fi

# -----------------------------------------------------------------------------
# Remove configuration files
# -----------------------------------------------------------------------------
echo "Removing configuration and state files..."
if [ -f "$CONFIG_FILE" ]; then
    rm -f "$CONFIG_FILE"
    echo "Configuration file removed."
else
    echo "Configuration file not found."
fi

rm -f "/etc/qfeeds/.last_sync" 2>/dev/null

if [ -d "/etc/qfeeds" ]; then
    rm -rf "/etc/qfeeds"
    echo "Configuration directory removed."
fi

# -----------------------------------------------------------------------------
# Remove log file
# -----------------------------------------------------------------------------
echo "Removing log file..."
if [ -f "$LOG_FILE" ]; then
    rm -f "$LOG_FILE"
    echo "Log file removed."
else
    echo "Log file not found."
fi

# -----------------------------------------------------------------------------
# Remove lock file and leftover temp files
# -----------------------------------------------------------------------------
if [ -f "/var/lock/qfeeds_blocklist.lock" ]; then
    rm -f "/var/lock/qfeeds_blocklist.lock"
    echo "Lock file removed."
fi
rm -f /tmp/qfeeds_* 2>/dev/null || true

echo "Q-Feeds Blocklist has been successfully uninstalled."
exit 0
