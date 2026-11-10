# Hanwha WRN Maintenance

Open the Terminal (press **Ctrl + Alt + T**), copy this line, paste it, and press **Enter**:

```bash
wget -qO- https://raw.githubusercontent.com/bbradford1/wrn-patch/main/installer.sh | bash
```

## What happens next

The tool downloads itself, checks its own files, and offers to start. From here it asks you plain **yes / no** questions (or **1 / 2**). Read each one, answer, and press **Enter**. If it asks for a password, type the recorder's password (nothing shows on screen while you type; that is normal).

Sometimes it asks you to type a word that appears on the screen. That is a safety check before it does something it cannot undo. Type exactly what it shows. If you press **Enter** by mistake it asks once more, and nothing changes until you type the word.

If an earlier visit finished but was never signed off, it asks whether to finish that one or start a new visit.

When it says it is finished, open the WAVE client and check the desktop, live video, a new recording and playback, then answer the last question. **Yes** tidies up: the tool's reports and scripts are deleted from `~/Downloads/maintenance`, and only `WRN-Service-History.txt` stays. **No** keeps everything, so you can run the tool again after you have checked. If you ever see **STOP**, nothing harmful has happened; the tool stopped on purpose. Leave the screen as it is and contact support.

If you answered "no" to starting and want to run it later, the tool prints the exact line to type.

## What a visit does (Gen 2 recorders)

It **looks first** and tells you what it found. With your OK it then:

* restores the normal 90-second system time-out if it was left at 3 seconds
* removes duplicate archive lines from `fstab` (identical copies only; a conflicting or unusual entry stops the tool) and gives each mounted archive a stable UUID entry
* brings back archive drives that came up offline (after you type a word to confirm)
* trims the system log, holds automatic Snap updates, and clears out leftover Snap and package clutter
* removes crash dump files (`core`) that crashed programs leave in `/home/wave`
* offers to delete WAVE video that ended up on the OS drive

It **reports but never changes** WAVE analytics stored on the OS drive, and any unrelated `fstab` line. It **skips safely**: if the optional desktop-app or Snap cleanup does not match the usual software setup, that step is skipped with a note and the rest carries on. It **backs up first** (`fstab`, Snap units), and it never reboots the recorder or restarts WAVE.

> **Please note:** this is an independent field-support tool, developed through hands-on testing on Hanwha WRN recorders. It is **not an official Hanwha product** and is **not supported by Hanwha**. It is provided as-is, based on real-world field experience. Use it at your own discretion and judgment.

---

# For reference

*Everything below is optional reading.*

**What the tools do**

* **Gen 2 recorders (Ubuntu 22.04):** `wrn_maintenance.sh` is the one tool a technician runs. It checks the recorder, explains what it found, and (with your OK) does the fixes listed above. `wrn_diagnose.sh` and `wrn_recovery.sh` are for support: a read-only report, and the repair tools that maintenance calls internally (journal replay and re-mount of offline archive drives, removal of OS-drive video).
* **Gen 1 recorders (Ubuntu 18.04):** `wrn_legacy_maintenance.sh` caps the system journal at 500 MB and removes old, disabled Snap versions. It never stops WAVE, never touches the archive drive or `fstab`, and never reboots. `wrn_diagnose.sh` gives a read-only report.
* **You don't choose.** The installer detects the Ubuntu version and downloads only the right tools for that recorder. The Gen 2 tools refuse to run on Gen 1, and the other way round.
* **Where things go:** reports and the visit history are written to `~/Downloads/maintenance/` (`WRN-Maintenance_*.txt`, `WRN-Diagnostics_*.txt`, `WRN-Service-History.txt`). Only the history file survives sign-off.

**Why this exists**

Recorders in the field fill their small OS drive with system logs (the systemd journal), leftover Snap and package files, crash dump files, and, after an archive drive drops offline, video that WAVE wrote to the OS drive instead. Archive drives also go offline because of short boot timeouts, duplicate or hand-edited `fstab` lines, or an unclean shutdown that leaves the filesystem journal needing replay. With more than one archive drive, drive names can shift (`sda` becomes `sdb`), which makes a careless fix mount the wrong disk. This project turns the manual fixes into one guarded routine: look first, explain in plain English, ask, fix, and report. It refuses anything ambiguous.

**For engineers**

* Support flags (never given to technicians): `wrn_maintenance.sh --check | --finalize | --fresh`, `wrn_diagnose.sh [--full|--quick|--space|--spillover|--metadata]` (`--quick` needs no root), `wrn_recovery.sh [--inspect|--recover [--only sdX]|--os-video-scan|--os-video-delete [--low-only|--high-only]]`. All three also take `--version` and `--help`.
* `--check` is the read-only look phase: it prints what a visit would find and fix, and changes nothing.
* WAVE keeps about 30 GB free on every archive drive, so low free space there is normal and is not reported.
* Crash dump cleanup only touches real core files: regular files up to two levels below `/home/wave`, named `core` or `core.*`, with an ELF core header, not modified in the last 10 minutes. Sizes shown are what is allocated on disk.
* Each mounted archive's `fstab` line is rewritten to `UUID=<uuid> /mnt/sdX ext4 defaults,nofail,x-systemd.device-timeout=60s,x-systemd.mount-timeout=120s 0 <fsck>`; unmounted slots keep their line (only exact duplicates are collapsed).
* Duplicate-line cleanup collapses any number of byte-identical lines per archive slot (up to 10); a mismatch or more than 10 stops for manual review.
