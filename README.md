# Hanwha WRN Maintenance

Open the Terminal (press **Ctrl + Alt + T**), copy this line, paste it, and press **Enter**:

```bash
wget -qO- https://raw.githubusercontent.com/bbradford1/wrn-patch/main/installer.sh | bash
```

## What happens next

The tool downloads itself, checks its own files, and offers to start. From here it asks you plain **yes / no** questions (or **1 / 2**). Read each one, answer, and press **Enter**. If it asks for a password, type the recorder's password (nothing shows on screen while you type; that is normal).

Sometimes it asks you to type a word that appears on the screen. That is a safety check before it does something it cannot undo. Type exactly what it shows.

When it says it is finished, open the WAVE client and check live video and playback, then answer the last question. If you ever see **STOP**, nothing harmful has happened; the tool stopped on purpose. Leave the screen as it is and contact support.

If you answered "no" to starting and want to run it later, the tool prints the exact line to type.

> **Please note:** this is an independent field-support tool, developed through hands-on testing on Hanwha WRN recorders. It is **not an official Hanwha product** and is **not supported by Hanwha**. It is provided as-is, based on real-world field experience. Use it at your own discretion and judgment.

---

# For reference

*Everything below is optional reading.*

**What the tools do**

* **Gen 2 recorders (Ubuntu 22.04):** `wrn_maintenance.sh` is the one tool a technician runs. It checks the recorder, explains what it found, and (with your OK) fixes boot-timeout and `fstab` problems, brings back archive drives that came up offline, trims leftover system and package clutter, and offers to remove WAVE video that ended up on the OS drive. `wrn_diagnose.sh` and `wrn_recovery.sh` are for support: a read-only report, and the repair tools that maintenance calls internally.
* **Gen 1 recorders (Ubuntu 18.04):** `wrn_legacy_maintenance.sh` caps the system journal at 500 MB and removes old, disabled Snap versions. It never stops WAVE, never touches the archive drive or `fstab`, and never reboots. `wrn_diagnose.sh` gives a read-only report.
* **You don't choose.** The installer detects the Ubuntu version and downloads only the right tools for that recorder. The Gen 2 tools refuse to run on Gen 1, and the other way round.

**Why this exists**

Recorders in the field fill their small OS drive with system logs (the systemd journal), leftover Snap and package files, and, after an archive drive drops offline, video that WAVE wrote to the OS drive instead. Archive drives also go offline because of short boot timeouts, duplicate or hand-edited `fstab` lines, or an unclean shutdown that leaves the filesystem journal needing replay. With more than one archive drive, drive names can shift (`sda` becomes `sdb`), which makes a careless fix mount the wrong disk. This project turns the manual fixes into one guarded routine: look first, explain in plain English, ask, fix, and report. It refuses anything ambiguous.

**For engineers**

* Support flags (never given to technicians): `wrn_maintenance.sh --check | --finalize | --fresh`, `wrn_diagnose.sh [--full|--quick|--space|--spillover|--metadata]`, `wrn_recovery.sh [--inspect|--recover [--only sdX]|--os-video-scan|--os-video-delete]`.
* WAVE keeps about 30 GB free on every archive drive, so low free space there is normal and is not reported.
