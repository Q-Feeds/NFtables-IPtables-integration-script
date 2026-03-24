<div align="center">

# 🛡️ Q-Feeds Linux Firewall Blocklist Integration

**Automated malware IP blocklist for Linux servers — supports nftables and iptables+ipset**

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Linux](https://img.shields.io/badge/Linux-nftables%20%7C%20iptables-orange)](https://netfilter.org/)

</div>

---

## 📋 Table of Contents

- [Quick Start](#-quick-start)
- [Overview](#-overview)
- [How It Works](#-how-it-works)
- [Prerequisites](#-prerequisites)
- [Detailed Installation](#-detailed-installation-guide)
- [Configuration](#-configuration)
- [Usage and Verification](#-usage-and-verification)
- [Troubleshooting](#-troubleshooting)
- [Uninstalling](#-uninstalling)
- [License](#-license)

---

## 🚀 Quick Start

### Step 1: Get your API token

Obtain a free API key at [tip.qfeeds.com](https://tip.qfeeds.com/).

### Step 2: Download the scripts

```bash
git clone https://github.com/Q-Feeds/NFtables-IPtables-integration-script.git
cd NFtables-IPtables-integration-script
chmod +x qfeeds-installer.sh qfeeds-uninstaller.sh
```

### Step 3: Run the installer as root

```bash
sudo ./qfeeds-installer.sh
```

The installer will:
1. **Auto-detect** your firewall backend (nftables or iptables)
2. Prompt you for your API token, blocking options, and optional whitelist
3. Install all dependencies, the updater script, and cron job
4. Perform the first full sync immediately

### Step 4: Done

Your server is now protected. The cron job checks for updates every 20 minutes (configurable), and actual API calls only happen when your license allows.

---

## 📖 Overview

This solution periodically downloads the latest threat intelligence feed from Q-Feeds and applies it as firewall rules, allowing you to:

- ✅ **Block incoming connections** from known malicious IPs
- ✅ **Block outgoing connections** to known malicious IPs
- ✅ **Whitelist your own IPs/CIDRs** so you never lock yourself out
- ✅ **Automatic scheduling** based on your Q-Feeds license
- ✅ **Incremental updates** via diff-based sync for minimal resource usage

### Why This Approach?

- ✅ **Auto-detects backend** — works on nftables or iptables+ipset without manual selection
- ✅ **Fast** — loads 400k+ IPs in seconds using optimized hash sets (nftables) or ipset (iptables)
- ✅ **Safe** — uses dedicated tables/sets — never touches your existing firewall rules
- ✅ **Efficient** — diff-based updates only process changes, not the full list
- ✅ **Reliable** — automatic fallback to full sync if a diff fails
- ✅ **Flexible** — choose incoming/outgoing blocking, optional whitelist

---

## 🔧 How It Works

### Backend Detection

The installer automatically detects which firewall backend is available:

| Priority | Detection | Backend |
|----------|-----------|---------|
| 1st | `nft` command found | **nftables** |
| 2nd | `iptables` command found | **iptables+ipset** |
| — | Neither found | Error (exit) |

The detected backend is stored in the configuration file. The updater and uninstaller scripts use it to run the correct firewall commands.

### Architecture: Two Set Types

Both backends use the same split-set strategy for maximum performance:

**nftables backend:**

```
┌─────────────────────────────────────────────────────────┐
│  table ip qfeeds                                        │
│                                                         │
│  ┌─────────────────────────┐  ┌───────────────────────┐ │
│  │ qfeeds_blacklist_v4     │  │ qfeeds_blacklist_v4   │ │
│  │ (hash set)              │  │ _nets (interval set)  │ │
│  │                         │  │                       │ │
│  │ Individual IPs          │  │ CIDR ranges           │ │
│  │ ~99% of entries         │  │ ~1% of entries        │ │
│  │ O(1) lookup & insert    │  │ O(log n) lookup       │ │
│  └─────────────────────────┘  └───────────────────────┘ │
│                                                         │
│  ┌─────────────────────────┐                            │
│  │ qfeeds_whitelist_v4     │                            │
│  │ (interval set)          │                            │
│  │ Your allowed IPs/CIDRs  │                            │
│  └─────────────────────────┘                            │
│                                                         │
│  chain input-chain (hook input, priority 0, accept)     │
│    → ip saddr @qfeeds_whitelist_v4 accept               │
│    → ip saddr @qfeeds_blacklist_v4 drop                 │
│    → ip saddr @qfeeds_blacklist_v4_nets drop            │
│                                                         │
│  chain output-chain (if enabled)                        │
│    → ip daddr @qfeeds_whitelist_v4 accept               │
│    → ip daddr @qfeeds_blacklist_v4 drop                 │
│    → ip daddr @qfeeds_blacklist_v4_nets drop            │
└─────────────────────────────────────────────────────────┘
```

**iptables+ipset backend:**

```
┌──────────────────────────────────────────────────────────┐
│  ipset sets                                              │
│                                                          │
│  ┌─────────────────────────┐  ┌────────────────────────┐ │
│  │ qfeeds_blacklist_v4     │  │ qfeeds_blacklist_v4    │ │
│  │ (hash:ip)               │  │ _nets (hash:net)       │ │
│  │ maxelem 1000000         │  │ maxelem 65536          │ │
│  │                         │  │                        │ │
│  │ Individual IPs          │  │ CIDR ranges            │ │
│  └─────────────────────────┘  └────────────────────────┘ │
│                                                          │
│  ┌─────────────────────────┐                             │
│  │ qfeeds_whitelist_v4     │                             │
│  │ (hash:net)              │                             │
│  └─────────────────────────┘                             │
│                                                          │
│  iptables rules (tagged with -m comment "qfeeds"):       │
│    INPUT  -m set --match-set whitelist_v4 src -j ACCEPT  │
│    INPUT  -m set --match-set blacklist_v4 src -j DROP    │
│    INPUT  -m set --match-set blacklist_v4_nets src -j DROP│
│    OUTPUT (if enabled) — same pattern with dst            │
└──────────────────────────────────────────────────────────┘
```

The same structure exists for IPv6 (`ip6 qfeeds` table or `ip6tables` + `family inet6` ipsets).

**Why two set types?**
- **Hash sets** store individual IPs with O(1) insert and lookup — loading 400k+ IPs takes seconds
- **Net/interval sets** are only used for the small number of CIDR ranges in the feed
- This avoids expensive merge operations that would slow down a single set with hundreds of thousands of entries

### Update Flow

```
┌──────────────────────────────────────────────────────┐
│  1. Check license schedule (licenses.php API)        │
│     → Skip run if not yet time for next update       │
│  2. Determine sync mode (full or diff)               │
│  3. Fetch IPv4 feed (ipv6=0) and IPv6 feed           │
│     (ipv6=only) separately                           │
│  4. Separate IPs from CIDRs in awk                   │
│  5. Batch-load into hash set (IPs) and net/interval  │
│     set (CIDRs)                                      │
│  6. Update whitelist sets from config                 │
│  7. Persist rules                                    │
└──────────────────────────────────────────────────────┘
```

### Full Sync vs Diff Sync

| Mode | When | What it does |
|------|------|-------------|
| **Full sync** | First run, forced update, or after diff failure | Flushes all blacklist sets and reloads from scratch |
| **Diff sync** | Subsequent runs (`malware_ip` feed only) | Fetches only additions (`+`) and removals (`-`) since last pull |

The diff sync is **per API key** — the API tracks your last successful pull and only returns changes since then. If a diff fails, the script automatically falls back to a full sync.

### License-Based Scheduling

The updater checks the Q-Feeds license API (`licenses.php`) before every run. If your license's `next_update` timestamp hasn't been reached yet, the script exits early without making unnecessary API calls. The cron job runs frequently (default: every 20 minutes), but actual updates only happen when your license allows.

---

## ✅ Prerequisites

Before installing, ensure you have:

- [x] **Linux server** with **nftables** or **iptables** (Debian, Ubuntu, CentOS, Fedora, Arch, Alpine)
- [x] **Root access** — the installer and updater must run as root
- [x] **Q-Feeds API Token** — get yours free at [tip.qfeeds.com](https://tip.qfeeds.com/)
- [x] **Internet access** — the server needs to reach `api.qfeeds.com`

The installer will automatically install required dependencies:
- **nftables backend**: `nftables`, `curl`, `jq`, `util-linux`
- **iptables backend**: `iptables`, `ipset`, `curl`, `jq`, `util-linux`

---

## 📝 Detailed Installation Guide

### 1. Get Your API Token

Visit [tip.qfeeds.com](https://tip.qfeeds.com/) to obtain your free Q-Feeds API token.

### 2. Download and Run

```bash
git clone https://github.com/Q-Feeds/NFtables-IPtables-integration-script.git
cd NFtables-IPtables-integration-script
chmod +x qfeeds-installer.sh qfeeds-uninstaller.sh
sudo ./qfeeds-installer.sh
```

### 3. Installer Prompts

The installer will ask the following questions:

#### API Token (required)

```
Enter your Q-Feeds API Token:
```

Your token from [tip.qfeeds.com](https://tip.qfeeds.com/). The installer refuses to continue if empty.

#### Feed Type

```
Enter feed type [default: malware_ip]:
```

Default is `malware_ip`. Only change this if Q-Feeds has provided you with a different feed type.

#### IP Limit

```
Enter the limit of IPs to fetch (leave empty for no limit):
```

Press Enter for no limit (recommended). Enter a number to cap the feed size.

#### Directional Blocking

```
Block INCOMING connections from malicious IPs? [Y/n]:
Block OUTGOING connections to malicious IPs? [y/N]:
```

- **Incoming** (default: yes) — blocks traffic *from* blacklisted IPs to your server
- **Outgoing** (default: no) — blocks traffic *from* your server *to* blacklisted IPs

#### Whitelist (optional)

```
Configure a whitelist of IPs/CIDRs that must NEVER be blocked? [y/N]:
Enter IPv4 whitelist (comma-separated, e.g. 1.2.3.4,5.6.7.8):
Enter IPv6 whitelist (comma-separated, e.g. 2001:db8::1):
```

Add your management IP(s) here to ensure you are never locked out, even if they appear in the feed. Whitelist rules are always checked **before** blacklist rules.

#### Cron Schedule

```
Enter cron schedule (e.g., '*/20 * * * *') [default: */20 * * * *]:
```

How often the updater checks for new data. Default is every 20 minutes. The license-based scheduling ensures the API is only called when your license allows an update.

---

## ⚙️ Configuration

All settings are stored in `/etc/qfeeds/qfeeds_config.conf`. You can edit this file directly without rerunning the installer. Changes take effect on the next cron run.

### Configuration File Reference

| Variable | Description | Default |
|----------|-------------|---------|
| `BACKEND` | Firewall backend (`nftables` or `iptables`) | *(auto-detected)* |
| `API_TOKEN` | Your Q-Feeds API token | *(required)* |
| `FEED_TYPE` | Feed type to fetch | `malware_ip` |
| `LIMIT` | Max IPs to fetch (empty = no limit) | *(empty)* |
| `BLOCK_INCOMING` | Block incoming from blacklisted IPs | `yes` |
| `BLOCK_OUTGOING` | Block outgoing to blacklisted IPs | `no` |
| `WHITELIST_V4` | Comma-separated IPv4 whitelist | *(empty)* |
| `WHITELIST_V6` | Comma-separated IPv6 whitelist | *(empty)* |
| `LOG_FILE` | Path to log file | `/var/log/qfeeds_blocklist.log` |

### Files Created by the Installer

| Path | Purpose |
|------|---------|
| `/etc/qfeeds/qfeeds_config.conf` | Configuration file |
| `/etc/qfeeds/.last_sync` | State file for full/diff sync tracking |
| `/usr/local/bin/update_qfeeds_blocklist.sh` | Updater script (runs via cron) |
| `/var/log/qfeeds_blocklist.log` | Log file |

---

## 🎯 Usage and Verification

### nftables backend

```bash
# Show the table structure and rules
nft list table ip qfeeds

# Count loaded IPv4 IPs (individual addresses)
nft list set ip qfeeds qfeeds_blacklist_v4 | grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l

# Show loaded CIDR ranges
nft list set ip qfeeds qfeeds_blacklist_v4_nets | head -20

# Count loaded IPv6 addresses
nft list set ip6 qfeeds qfeeds_blacklist_v6 | wc -l
```

### iptables+ipset backend

```bash
# List all Q-Feeds ipsets and their sizes
ipset list -t | grep -A4 qfeeds

# Count loaded IPv4 IPs
ipset list qfeeds_blacklist_v4 | tail -n +9 | wc -l

# Show loaded CIDR ranges
ipset list qfeeds_blacklist_v4_nets | tail -n +9 | head -20

# Show iptables rules with qfeeds comment
iptables -L INPUT -n --line-numbers | grep qfeeds
ip6tables -L INPUT -n --line-numbers | grep qfeeds
```

### Common commands (both backends)

```bash
# Check the log (last 20 entries)
tail -20 /var/log/qfeeds_blocklist.log

# Check for errors
grep -i "error" /var/log/qfeeds_blocklist.log

# Normal run (respects license schedule)
sudo /usr/local/bin/update_qfeeds_blocklist.sh

# Force a full sync (ignores schedule, reloads everything)
sudo QFEEDS_FORCE_UPDATE=1 /usr/local/bin/update_qfeeds_blocklist.sh

# Verify cron is set up
sudo crontab -l | grep qfeeds
```

---

## 🔍 Troubleshooting

### General

**Installation fails with "Unable to locate package"**
- The installer auto-detects your distro (Debian/Ubuntu, CentOS/RHEL, Fedora, Arch, Alpine). If detection fails, install dependencies manually: `curl`, `jq`, `util-linux` (for `flock`), plus `nftables` or `iptables`+`ipset`.

**Sets are empty after installation**
- Check the log: `tail -50 /var/log/qfeeds_blocklist.log`
- Verify your API token is correct
- Try a forced update: `sudo QFEEDS_FORCE_UPDATE=1 /usr/local/bin/update_qfeeds_blocklist.sh`

**"Not time yet. Next update scheduled at..."**
- The updater respects your license schedule. This message means the cron ran, but your license doesn't allow an update yet. This is normal — the next cron run will check again.
- The Linux installer keeps a local cached `licenses.php` index and uses the cached `next_update` as its schedule gate. After a successful pull it refreshes that local index for the next cycle.

**Rules don't persist after reboot**
- If `netfilter-persistent` is installed, rules are saved automatically
- **nftables**: manually save with `nft list ruleset > /etc/nftables.conf`
- **iptables**: manually save with `iptables-save > /etc/iptables.rules` and `ipset save > /etc/ipset.conf`
- The cron job will also reload the rules on the next run

### nftables-specific

**"Batch nft -f failed. Falling back to per-command execution..."**
- This is normal, especially on LXC containers where the kernel's netlink buffer (`wmem_max`) is restricted. The per-command fallback works correctly and is fast (~10 seconds for 400k+ IPs).

**Syntax error: "unexpected string"**
- Ensure you're running a recent version of nftables. The script uses `ip saddr`/`ip daddr` syntax which requires nftables 0.9+.

**"Error: Could not process rule: Message too long"**
- This is the netlink buffer limit, typically in LXC containers. The script automatically falls back to per-command execution. If you see this in the log alongside a successful load, it's working as intended.

### iptables+ipset-specific

**"ipset restore failed"**
- Check that `ipset` is installed: `command -v ipset`
- Check the log for specific errors: `grep -i "error" /var/log/qfeeds_blocklist.log`
- Ensure the ipset module is loaded: `lsmod | grep ip_set`

**iptables rules not showing up**
- Verify rules with: `iptables -L INPUT -n | grep qfeeds`
- The rules use `-m comment --comment "qfeeds"` for identification
- Ensure the `xt_set` module is loaded: `modprobe xt_set`

**"ipset create ... failed"**
- On very old kernels, `hash:ip` or `hash:net` types may not be available. Upgrade your kernel or install `ipset` from a newer repository.

---

## 🗑️ Uninstalling

```bash
sudo ./qfeeds-uninstaller.sh
```

The uninstaller removes everything based on the detected backend:

**nftables backend:**
- Deletes `ip qfeeds` and `ip6 qfeeds` tables (including all chains, rules, and sets)

**iptables backend:**
- Removes all iptables/ip6tables rules tagged with the `qfeeds` comment
- Destroys all ipset sets (`qfeeds_blacklist_v4`, `qfeeds_blacklist_v4_nets`, `qfeeds_whitelist_v4`, and IPv6 equivalents)

**Both backends:**
- Configuration directory (`/etc/qfeeds/`)
- Updater script (`/usr/local/bin/update_qfeeds_blocklist.sh`)
- Cron job, log file, and lock file

If the config file is missing, the uninstaller tries cleanup for **both** backends.

> **Note:** The uninstaller does **not** remove system packages (curl, jq, ipset, etc.) that were installed as dependencies.

---

## 📄 License

This project is licensed under the **Apache License 2.0** - see the [LICENSE](LICENSE) file for details.

---

## ⚠️ Disclaimer

**Use at your own risk.**

Please test these scripts in your environment before deploying them in production. The author is not responsible for any issues or damages that may occur from their use.

---

<div align="center">

[Report Bug](https://github.com/Q-Feeds/NFtables-IPtables-integration-script/issues) · [Request Feature](https://github.com/Q-Feeds/NFtables-IPtables-integration-script/issues)

</div>
