<div align="center">

# 🛡️ Q-Feeds NFtables Blocklist Integration

**Automated malware IP blocklist for Linux servers using nftables**

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Linux](https://img.shields.io/badge/Linux-nftables-orange)](https://netfilter.org/projects/nftables/)

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
chmod +x NFtables-installer.sh NFtables-uninstaller.sh
```

### Step 3: Run the installer as root

```bash
sudo ./NFtables-installer.sh
```

The installer will prompt you for your API token, blocking options, and optional whitelist.

### Step 4: Done

The installer automatically:
- Creates the configuration at `/etc/qfeeds/qfeeds_config.conf`
- Installs the updater script at `/usr/local/bin/update_qfeeds_blocklist.sh`
- Sets up a cron job (default: every 20 minutes)
- Runs an initial full sync to load the blocklist immediately

---

## 📖 Overview

This solution periodically downloads the latest threat intelligence feed from Q-Feeds and applies it as nftables firewall rules, allowing you to:

- ✅ **Block incoming connections** from known malicious IPs
- ✅ **Block outgoing connections** to known malicious IPs
- ✅ **Whitelist your own IPs/CIDRs** so you never lock yourself out
- ✅ **Automatic scheduling** based on your Q-Feeds license
- ✅ **Incremental updates** via diff-based sync for minimal resource usage

### Why This Approach?

- ✅ **Fast**: Loads 400k+ IPs in ~10 seconds using optimized hash sets
- ✅ **Safe**: Dedicated `qfeeds` table — never touches your existing firewall rules
- ✅ **Efficient**: Diff-based updates only process changes, not the full list
- ✅ **Reliable**: Automatic fallback to full sync if a diff fails
- ✅ **Flexible**: Choose incoming/outgoing blocking, optional whitelist

---

## 🔧 How It Works

### Architecture: Two Set Types

The script uses a split-set architecture for maximum performance:

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

The same structure exists for IPv6 under `table ip6 qfeeds`.

**Why two set types?**
- **Hash sets** store individual IPs with O(1) insert and lookup — loading 400k+ IPs takes seconds
- **Interval sets** (with `auto-merge`) are only used for the small number of CIDR ranges in the feed
- This avoids the expensive merge operations that would slow down a single interval set with hundreds of thousands of entries

### Update Flow

```
┌──────────────────────────────────────────────────────┐
│  1. Check license schedule (licenses.php API)        │
│     → Skip run if not yet time for next update       │
│  2. Determine sync mode (full or diff)               │
│  3. Fetch IPv4 feed (ipv6=0) and IPv6 feed           │
│     (ipv6=only) separately                           │
│  4. Separate IPs from CIDRs in awk                   │
│  5. Batch-load into hash set (IPs) and interval      │
│     set (CIDRs)                                      │
│  6. Update whitelist sets from config                 │
│  7. Persist rules (netfilter-persistent or manual)    │
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

- [x] **Linux server** with `nftables` installed (Debian, Ubuntu, CentOS, Fedora, Arch, Alpine)
- [x] **Root access** — the installer and updater must run as root
- [x] **Q-Feeds API Token** — get yours free at [tip.qfeeds.com](https://tip.qfeeds.com/)
- [x] **Internet access** — the server needs to reach `api.qfeeds.com`

The installer will automatically install required dependencies (`curl`, `jq`, `util-linux` for `flock`).

---

## 📝 Detailed Installation Guide

### 1. Get Your API Token

Visit [tip.qfeeds.com](https://tip.qfeeds.com/) to obtain your free Q-Feeds API token.

### 2. Download and Run

```bash
git clone https://github.com/Q-Feeds/NFtables-IPtables-integration-script.git
cd NFtables-IPtables-integration-script
chmod +x NFtables-installer.sh NFtables-uninstaller.sh
sudo ./NFtables-installer.sh
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

### Check if the blocklist is loaded

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

### Check the log

```bash
# Last 20 log entries
tail -20 /var/log/qfeeds_blocklist.log

# Check for errors
grep -i "error" /var/log/qfeeds_blocklist.log
```

### Manually trigger an update

```bash
# Normal run (respects license schedule)
sudo /usr/local/bin/update_qfeeds_blocklist.sh

# Force a full sync (ignores schedule, reloads everything)
sudo QFEEDS_FORCE_UPDATE=1 /usr/local/bin/update_qfeeds_blocklist.sh
```

### Verify cron is set up

```bash
sudo crontab -l | grep qfeeds
```

---

## 🔍 Troubleshooting

**Installation fails with "Unable to locate package"**
- The installer auto-detects your distro (Debian/Ubuntu, CentOS/RHEL, Fedora, Arch, Alpine). If detection fails, install dependencies manually: `curl`, `jq`, `util-linux` (for `flock`).

**"Batch nft -f failed. Falling back to per-command execution..."**
- This is normal, especially on LXC containers where the kernel's netlink buffer (`wmem_max`) is restricted. The per-command fallback works correctly and is fast (~10 seconds for 400k+ IPs).

**Sets are empty after installation**
- Check the log: `tail -50 /var/log/qfeeds_blocklist.log`
- Verify your API token is correct
- Try a forced update: `sudo QFEEDS_FORCE_UPDATE=1 /usr/local/bin/update_qfeeds_blocklist.sh`

**"Not time yet. Next update scheduled at..."**
- The updater respects your license schedule. This message means the cron ran, but your license doesn't allow an update yet. This is normal — the next cron run will check again.

**Syntax error: "unexpected string"**
- Ensure you're running a recent version of nftables. The script uses `ip saddr`/`ip daddr` syntax which requires nftables 0.9+.

**"Error: Could not process rule: Message too long"**
- This is the netlink buffer limit, typically in LXC containers. The script automatically falls back to per-command execution. If you see this in the log alongside a successful load, it's working as intended.

**Rules don't persist after reboot**
- If `netfilter-persistent` is installed, rules are saved automatically. Otherwise, save manually:
  ```bash
  nft list ruleset > /etc/nftables.conf
  ```
- The cron job will also reload the rules on the next run.

---

## 🗑️ Uninstalling

```bash
sudo ./NFtables-uninstaller.sh
```

The uninstaller removes everything:
- nftables tables (`ip qfeeds`, `ip6 qfeeds`) and all their sets, chains, and rules
- Configuration directory (`/etc/qfeeds/`)
- Updater script (`/usr/local/bin/update_qfeeds_blocklist.sh`)
- Cron job, log file, and lock file

> **Note:** The uninstaller does **not** remove system packages (curl, jq, etc.) that were installed as dependencies.

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
