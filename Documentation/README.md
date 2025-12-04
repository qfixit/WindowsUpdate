# Windows 11 Upgrade (25H2) – Technicians' Guide (v2.7.0)

## Overview
- Stages Windows 11 25H2 from ISO using `setup.exe` with `/Quiet` and `/noreboot` (script triggers `shutdown /r /t 0` at the end when `AutoReboot` is true).
- Entry script (modular): `Windows11Upgrade.ps1` loads helpers under the same folder.
- Logs to `C:\Windows11UpgradeLog.txt`.
- State markers: `C:\Temp\WindowsUpdate\ScriptRunning.txt`, `PendingReboot.txt`, `UpgradeFailed.txt`.
- Toast assets/scripts live in `WindowsUpdate\Toast-Notification`; tasks schedule reboot reminders. Post-reboot validation uses RunOnce only (no scheduled task); cleanup can be triggered after upgrade if needed.

## Key Paths & Artifacts
- ISO: `C:\Temp\WindowsUpdate\Windows11_25H2.iso` (hash cache `.iso.sha256`).
- Setup logs copied to `C:\Temp\WindowsUpdate\SetupLogs`.
- Post-reboot script: `C:\Temp\WindowsUpdate\Windows11Upgrade.ps1` (reuses the main orchestrator).
- Toast assets: `C:\Temp\WindowsUpdate\Toast-Notification\hero.jpg` / `logo.jpg`.

## Tasks & Notifications
- Reboot reminders: `Win11_RebootReminder_1` / `_2` (uses configured times).
- Post-reboot validation uses only RunOnce to relaunch the orchestrator; no scheduled task is registered.
- Toast scripts: `Toast-Windows11Download.ps1`, `Toast-Windows11RebootReminder.ps1` (run via scheduled tasks for reminders).

## Preflight / Gating
- SentinelOne version gate: requires ≥ 24.2.2.0 or maintenance mode; otherwise writes `UpgradeFailed.txt`.
- Hardware checks: TPM 2.0, Secure Boot, 64-bit CPU, RAM ≥ 4 GB, disk space check (64 GB default).

## Logs & Troubleshooting
- Main log: `C:\Windows11UpgradeLog.txt`. Watch for:
  - Duration formatting warnings (resolved in v2.5.7+ with invariant formatting).
  - Task registration errors: check `schtasks` command/output in log and verify paths for `Toast-Notification` scripts and PowerShell (`System32\WindowsPowerShell\v1.0\powershell.exe`).
- Failure marker: `C:\Temp\WindowsUpdate\UpgradeFailed.txt` (contains reason). Pending state: `PendingReboot.txt`.
- Self-repair: reruns staging if device rebooted without completing upgrade; cleans stale artifacts on failure.

## Quick Local Smoke Test (no RMM)
```powershell
cd .\Windows11Upgrade
. .\UpgradeConfig.ps1; Set-UpgradeConfig | Out-Null
.\Windows11Upgrade.ps1 -VerboseLogging
```

## Notes
- Keep `WindowsUpgrade` folder intact; scripts expect relative module paths.
- Do not rename marker files (`PendingReboot.txt`, `UpgradeFailed.txt`); monitors depend on them.
- Ensure `hero.jpg` and `logo.jpg` are present in the toast folder before scheduling reminders.
- Successful post-upgrade cleanup removes `C:\Temp\WindowsUpdate` (including the staged scripts) and archives setup logs; only the main log remains.
- RunOnce is created for post-reboot validation; ConnectWise RMM can still trigger `PostUpgradeCleanup.ps1` after the device has upgraded.

---

# Changelog

## 2.7.0 - 2025-12-03
- Progress toasts rebuilt with install/download phases, single notification per phase, and optional end-user guide link.
- Toast AUMID now uses a Koltiv shortcut with fallback creation paths to avoid SYSTEM profile write errors.
- Config/RMM emit now carries `DocLink` (@UpgradeGuide@) for the guide button in toasts.
- Version headers and Version.txt updated for the 2.7.0 release.

## 2.6.3 - 2025-12-01
- Enforced single-instance execution with a global mutex and process check; extra invocations exit quietly.
- Added error code catalog (`ErrorCodes.ps1`) and structured logging for technician-friendly remediation.
- BITS hygiene: cleans `BIT*.tmp` on start, removes undersized downloads, retries ISO download via BITS then Invoke-WebRequest fallback.
- Staging retries mount/setup up to 3 times, cleans corrupt media and `$WINDOWS.~BT` on 0xC1900107, logs 0xC1900208 blocks.
- Post-reboot validation now RunOnce-only and runs hidden to avoid user-visible windows.
- Self-repair restages after reboot interruptions and re-registers RunOnce/reminders.

## 2.6.1 - 2025-11-30
- Removed internal post-reboot validation task/runonce; cleanup is now triggered by ConnectWise RMM calling `PostUpgradeCleanup.ps1`.
- RMM config always overwrites `config.json`; runtime no longer falls back to any default configuration file.
- SentinelOne gate skips cleanly when the agent is absent; version enforcement applies only when installed.

## 2.6.0 - 2025-11-30
- Configuration now loads from JSON (RMM writes `config.json`; packaged default ships as `config.default.json`) with no computer-specific log fallback.
- setup.exe always runs with `/noreboot`; when `AutoReboot` is true, the script triggers `shutdown /r /t 0` after staging completes so tasks and reminders are registered first.
- Removed unused reboot event logging helper and simplified module loading to rely on `$PSScriptRoot` and helper discovery.
- RMM builder now outputs `config.json` with `@Parameter@` tokens for ConnectWise substitution.

## 2.5.9 - 2025-11-29
- Post-reboot validation now reuses `Windows11Upgrade.ps1` and registers `Win11_PostRebootValidation` on logon (with RunOnce fallback) so cleanup runs after user logon.
- Cleanup retries removal of `C:\Temp\WindowsUpdate` up to 3 times; if still present, it retains the validation task and re-registers RunOnce to keep retrying until the folder is gone.

## 2.5.8 - 2025-11-29
- Removed unused `C:\Temp\ToastAssets` creation and added cleanup coverage for any remnants.
- Post-upgrade cleanup now always logs to the primary log file and removes `C:\Temp\WindowsUpdate` (including staged scripts) after success.
- Hardened task registration deletes to ignore missing-task errors and tightened duration formatting with invariant culture.

## 2.5.7 - 2025-11-28
- Hardened duration formatting (TryParse) for ISO/setup phases and execution summaries to eliminate `TimeSpan` string errors.
- Reboot reminder tasks now launch the toast with a hidden PowerShell window and more resilient `privateRoot` resolution/logging.
- RMM config emitter rewritten with token replacement to avoid malformed `SetupExeArguments`, always overwrites the resolved config, and Version.txt added for current version/date.

## 2.5.6 - 2025-11-28
- Embedded changelog into README and removed standalone CHANGELOG.md; Version.txt introduced to track version/date.
- Download helper now deletes the ZIP after extraction; clarified local toast asset expectations.

## 2.5.5 - 2025-11-28
- RMM config supports direct parameter overrides (ISO URL/hash, DynamicUpdate, AutoReboot, reminder times) and local toast assets; emits the resolved UpgradeConfig automatically.
- Normalized header dates/author remarks across scripts.

## 2.5.4 - 2025-11-28
- Default AutoReboot now false (adds `/noreboot`), DynamicUpdate toggleable, local toast assets favored, and entry script consolidated to `Windows11Upgrade.ps1`.

## 2.5.1 - 2025-11-28
- Hardened ISO/setup duration logging so formatting errors can no longer abort staging after a successful download; duration strings now fall back gracefully while still recording warnings.
- Ensured ISO downloads proceed to hash validation/caching even if duration formatting misbehaves, preventing false `Failed to download ISO` interruptions once media is present.

## 2.5.0 - 2025-11-28
- Split the upgrade script into modular helpers under `Private/` (`Toast-Notification`, `ISO Download`, `Post-Upgrade Cleanup`) with the entry point now in `Public/Windows11Upgrade_v2.5.0.ps1` for zip-based deployment.
- Added early module-load validation so staging aborts with a clear error if any helper script is missing, keeping the new zip layout predictable for RMM delivery.
- Each helper script now carries version/date headers plus example test commands, and the cleanup module offers a `-ListCleanupTargets` preview to validate post-upgrade tidy-up safely.

## 2.4.1 - 2025-11-27
- Fixed toast delivery failures (“system cannot find the file specified”) by writing helper scripts to stable paths and invoking toasts via absolute `wscript.exe`/`powershell.exe` paths with richer schtasks logging when creation/run fails.
- Simplified progress logging strings to `ISO download progress X%` and `Install progress X%`.
- Stopped logging the benign “BITS job disappeared” warning after transfers finish by breaking the poll loop as soon as the transfer completes.

## 2.4.0 - 2025-11-27
- Added a download-in-progress toast that fires from inside the ISO download routine so users are notified whenever a new ISO transfer starts, with failures logged as warnings only.

## 2.4.7 - 2025-11-06
- Rebuilt toast delivery to match the earlier working flow: recreate the VBS launcher, build a single quoted `/TR` string (`"wscript.exe" "RunHidden_*.vbs" "Toast-*.ps1"`), and invoke `schtasks.exe` directly (delete/create/run) so download toasts no longer hit argument-binding errors. Kept the DEBUG logs for paths and schtasks commands/outputs to aid troubleshooting.

## 2.4.6 - 2025-11-05
- Added a `DEBUG` log level and detailed toast diagnostics (path existence/metadata, schtasks commands, create/run outputs, action command) to pinpoint “file not found” causes when download toasts fail.
- Simplified toast preparation to use only script/VBS prerequisites and log their presence explicitly before scheduling the task.

## 2.4.5 - 2025-11-04
- Reverted toast launcher to the simpler v2.3.4 model: recreate the VBS launcher per toast, launch via `wscript.exe` with an immediate schtasks trigger, and drop the extra launcher parameter handling to avoid “file not found” errors.
- Toast failure logging now includes each expected path (script/vbs/wscript/powershell) to pinpoint missing files.

## 2.4.4 - 2025-11-03
- Fixed toast launcher paths to use the correct `System32\wscript.exe`/PowerShell paths (no extra backslashes) so scheduled toast tasks no longer throw “system cannot find the file specified.”

## 2.4.3 - 2025-11-03
- Restored the hidden VBScript launcher and now pass both the toast script and launcher paths into the scheduled task to stop “system cannot find the file specified” failures when firing the download toast.
- Prepare toast now returns both assets and the launcher so the BITS start toast reuses the same verified paths.

## 2.4.2 - 2025-11-02
- Pre-created the download toast helper (including cached hero/logo assets) before firing the first notification so the kickoff toast no longer fails when assets aren’t ready.
- Toast templates now honor existing cached images instead of re-downloading on every run, reducing download toast flakiness when connectivity is limited.

## 2.3.1 - 2025-11-06
- Updated the upgrade script metadata and expanded logging so pre/post reboot actions are written to `C:\Windows11UpgradeLog.txt`.
- Reworked reboot reminders to fall back to interactive logon triggers when no user is active, while still scheduling immediate reminders when a user is present.
- Added post-upgrade cleanup that archives setup logs, removes transient staging files/ISO, and marks `UpgradeState.json` as `Completed`.
- Hardware compatibility checks now run before downloading the Windows 11 ISO to avoid large transfers on unsupported devices.
- Added detailed ISO download progress logging (5% increments) to help with staging diagnostics.
- Fixed BITS cleanup calls (`Complete/Remove-BitsTransfer`) to use the correct `-BitsJob` parameter so asynchronous downloads no longer throw `parameter name 'BitsTransfer'` errors at completion.
- Retains primary logging to `C:\Windows11UpgradeLog.txt` throughout the workflow.
- Fixed the execution summary formatter so it tolerates missing duration values (no more `Cannot convert null to type "System.TimeSpan"` errors when a phase hasn’t run).
- Updated SentinelOne version detection to read DisplayVersion from the standard uninstall registry keys, matching how Add/Remove Programs reports the agent.
- Extended `Collect-Windows11UpgradeLogs.ps1` coverage to additional post-upgrade log locations (Windows.old) and enhanced environment reporting.

## 2.3 - 2025-11-06
- Removed all `$GetCurrent\Media` backup, validation, and reboot guard logic now that the ISO flow completes staging and cleans up automatically.
- Simplified the self-repair path to restage directly from the ISO, re-schedule reboot reminders, and reissue the user toast without restoring media artifacts.
- Added consolidated timing summary logs (total runtime, ISO download, setup execution) that print at script exit to support RMM monitoring.

## 2.2 - 2025-11-05
- Reworked logging to use shared file handles with retries so RMM/AV reads no longer throw `Stream was not readable` errors.
- Broadened SentinelOne detection (extra registry paths + service check) and block upgrade when version is missing or below 24.2.2, cleaning up staged artifacts when blocked.
- Cached toast hero images from the web with local fallbacks for both staging and reminder notifications.
- Protected media restoration by validating the target path and added retry logic when launching `setuphost` so occasional assistant hiccups auto-retry.

## 2.1 - 2025-11-03
- Added event-driven reboot guard with Win32 shutdown blocking so user restarts pause until media is restored and then resume automatically.
- Hardened guard registration/cleanup to handle standalone execution and ensure state artifacts are written.
- Expanded staging verification to validate guard tasks/scripts alongside media backups.

## 2.0 - 2025-02-17
- Added structured logging with optional `-VerboseLogging` switch and persistent state tracking to `C:\Windows11UpgradeLog.txt`.
- Implemented backup/restore workflow for `C:\$GetCurrent\media` with self-healing on failed upgrades.
- Introduced scheduled reboot reminders (11 AM, 4 PM) that reuse the toast notification framework.
- Added self-repair and post-upgrade cleanup routines to restore staging artifacts, re-register tasks, and tidy reminders while retaining logs.
- Refreshed the main execution flow to detect incomplete upgrades after reboot and resume gracefully.

## 1.9.2 - 2025-10-31
- Preserves extracted setup media from `$GetCurrent\media`/`$WINDOWS.~BT` into `C:\Temp\Windows11Upgrade`, kills the Assistant to stop forced reboots, and schedules setup.exe to run silently on the next restart.
- Adds SentinelOne version gating, detailed hardware checks, and thorough logging to `C:\Windows11UpgradeLog.txt` before staging continues.
- Deploys user-facing toasts plus daily 11 AM/4 PM reboot reminder tasks that self-remove once Windows 11 is detected and cleans up staged media post-upgrade.

## 1.8 - 2025-02-17
- Sends a user toast (with support mailto/phone) via a hidden scheduled task, storing helper scripts under `C:\Temp` and cleaning them up after execution.
- Waits for setup-related processes, then stops the Upgrade Assistant to prevent auto-reboot while continuing to monitor setup completion.
- Retains TPM/Secure Boot/CPU/RAM/disk checks and console/log output to `C:\Windows11UpgradeLog.txt`.

## 1.7 (Trimmed) - 2025-02-20
- White-label variant of 1.7 with placeholder branding/contact details, using the same staged-upgrade flow and toast scheduling while cleaning up helper scripts from `C:\Temp`.

## 1.7 - 2025-02-17
- Added ACS-branded toast notification with support links, run via a VBScript-wrapped scheduled task in the logged-in user context.
- Streamlined real-time logging/exception handling and continued hardware gating while killing the Upgrade Assistant after setuphost/setupprep start to avoid forced reboot.

## 1.6 - 2025-02-17
- Introduced a toast notification script (with hero/logo assets) dispatched through a temporary scheduled task and hidden VBScript runner for the logged-in user.
- Waits for setup/setupprep to spin up, then terminates `windows10upgraderapp.exe` to block auto-reboot and monitors all setup processes to exit cleanly.
- Ensured `C:\Temp` assets are created as needed and logs all actions to `C:\Windows11UpgradeLog.txt`.

## 1.5 - 2025-02-11
- Watches for `setup.exe` to appear before treating staging as successful, then prevents reboots and monitors setup until exit.
- Keeps TPM/Secure Boot/CPU/RAM/disk validation and logs the entire flow to `C:\Windows11UpgradeLog.txt`.

## 1.4 - 2025-02-11
- Added `Prevent-Reboot` to abort shutdowns and delete scheduled reboot tasks after staging so the upgrade waits for a manual restart.
- Hardened readiness checks with terminating errors for missing TPM/Secure Boot/CPU/RAM/disk prerequisites and consistent logging.

## 1.3 - 2025-01-29
- Strengthened hardware validation (throws on missing TPM/Secure Boot/CPU/RAM/storage) and switched to actively monitoring `setup.exe` start/exit for status logging.
- Runs the Installation Assistant with `/QuietInstall /SkipEULA /Auto Upgrade`, waiting on the process to finish before marking success.

## 1.2 - 2025-01-28
- Switched to downloading the Windows 11 Installation Assistant and running it silently with `/quietinstall /skipeula /auto upgrade`.
- Added TPM 2.0, Secure Boot, 64-bit CPU, RAM (≥4 GB), and storage (≥64 GB) checks plus simple status monitoring/logging to `C:\Windows11UpgradeLog.txt`.

## 1.1 - 2025-01-28
- Initial PSWindowsUpdate-based upgrade: installs the Windows 11 feature update when present, with optional automatic or scheduled reboot handling and log directory creation at `C:\Windows11_Upgrade_Logs`.
