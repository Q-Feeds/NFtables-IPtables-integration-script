#!/bin/bash
# =============================================================================
# Q-Feeds Blocklist Uninstaller Script (nftables Edition)
# =============================================================================
# This script removes the Q-Feeds Blocklist from your system, including
# configuration files, cron jobs, nftables tables/sets, and logs.
#
# It does NOT remove any system packages or dependencies that were installed.
# =============================================================================

set -e

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This uninstaller must be run as root."
    exit 1
fi

echo "Q-Feeds Blocklist Uninstaller (nftables Edition)"

# Confirm uninstallation
read -rp "Are you sure you want to uninstall the Q-Feeds Blocklist? (yes/no): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Uninstallation aborted."
    exit 0
fi

# Load configuration
CONFIG_FILE="/etc/qfeeds/qfeeds_config.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Configuration file not found at $CONFIG_FILE"
    echo "Using default nft set names and log file location."
    NFT_SET_NAME_V4="qfeeds_blacklist_v4"
    NFT_SET_NAME_V6="qfeeds_blacklist_v6"
    LOG_FILE="/var/log/qfeeds_blocklist.log"
fi

# Remove cron job
echo "Removing cron job..."
CRON_CMD="/usr/local/bin/update_qfeeds_blocklist.sh"
(crontab -l 2>/dev/null | grep -v "$CRON_CMD") | crontab -
echo "Cron job removed."

# -----------------------------------------------------------------------------
# Remove nftables rules, sets, and tables
# -----------------------------------------------------------------------------
echo "Removing nftables rules..."

# Deleting the entire table removes all chains, rules, and sets atomically.
# This avoids "Device or resource busy" errors from trying to delete sets
# that are still referenced by rules.

# IPv4 side
if nft list table ip qfeeds &>/dev/null; then
    nft delete table ip qfeeds
    echo "Deleted IPv4 table 'qfeeds' (including all chains, rules, and sets)."
else
    echo "No IPv4 nftable 'qfeeds' found."
fi

# IPv6 side
if nft list table ip6 qfeeds &>/dev/null; then
    nft delete table ip6 qfeeds
    echo "Deleted IPv6 table 'qfeeds' (including all chains, rules, and sets)."
else
    echo "No IPv6 nftable 'qfeeds' found."
fi

# If netfilter-persistent is available, save the changes
if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
    echo "Saved nftables rules using netfilter-persistent."
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

echo "Q-Feeds Blocklist has been successfully uninstalled (nftables)."
exit 0
