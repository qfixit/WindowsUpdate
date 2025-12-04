# Upgrade to Windows 11 (25H2) – RMM Task

## Summary

Use this task to stage Windows 11 25H2 via ISO with `Windows11Upgrade.ps1`. It performs hardware/SentinelOne gates, downloads/validates the ISO, mounts and runs setup, registers reboot reminder and post-reboot validation tasks, and logs to `C:\Windows11UpgradeLog.txt`. Reboot is not forced unless you allow it.
## Requirements

- PowerShell v5+
## Sample Run

![SampleRun-Select.png](../../Documentation/Connectwise%20RMM%20Task/SampleRun-Select.png)
![SampleRun-ConfigureSetup.png](../../Documentation/Connectwise%20RMM%20Task/SampleRun-ConfigureSetup.png)
![SampleRun-Schedule.png](../../Documentation/Connectwise%20RMM%20Task/SampleRun-Schedule.png)
## User Parameters
- Windows11IsoUrl (default: SharePoint ISO link)
	Direct download URL for the Windows 11 25H2 ISO.
- ISOHash (default: known SHA256)
	Expected SHA256 for the ISO; used to validate the download.
- DynamicUpdate (default: True)
	True includes `/DynamicUpdate Enable` in setup.exe; False uses `/DynamicUpdate Disable`. [/DynamicUpdate Reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options?view=windows-11#dynamicupdate)
- AutoReboot (default: False)
	False adds `/NoReboot` so the device will not reboot automatically; True omits `/NoReboot`. [/NoReboot Reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options?view=windows-11#noreboot)
- RebootReminder1Time (default: 11:00)
	Daily time (24-hour) for the first reboot reminder toast/task.
- RebootReminder2Time (default: 16:00)
	Daily time (24-hour) for the second reboot reminder toast/task.


| Name                  | Example                                                          | Accepted Values | Required | Default | Type | Description                                                                                                                                                                                                                                                  |
| --------------------- | ---------------------------------------------------------------- | --------------- | -------- | ------- | ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Windows11IsoUrl`     | https://linktodownloadWindowsISO.com                             |                 | True     |         | Text | Direct download URL for the Windows 11 ISO.                                                                                                                                                                                                                  |
| `ISOHash`             | D141F6030FED50F75E2B03E1EB2E53646C4B21E5386047CB860AF5223F102A32 |                 | True     |         | Text | Expected SHA256 for the ISO; used to validate the download.                                                                                                                                                                                                  |
| `DynamicUpdate`       | yes                                                              | yes, no         | True     | yes     | Flag | True includes `/DynamicUpdate Enable` in setup.exe; False uses `/DynamicUpdate Disable`. [/DynamicUpdate Reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options?view=windows-11#dynamicupdate) |
| `AutoReboot`          | no                                                               | yes, no         | True     | no      | Flag | False adds `/NoReboot` so the device will not reboot automatically; True omits `/NoReboot`. [/NoReboot Reference](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options?view=windows-11#noreboot)        |
| `RebootReminder1Time` | 11:00                                                            | HH:MM           | True     | 11:00   | Text | Daily time (24-hour) for the first reboot reminder toast/task.                                                                                                                                                                                               |
| `RebootReminder2Time` | 16:00                                                            | HH:MM           | True     | 16:00   | Text | Daily time (24-hour) for the second reboot reminder toast/task.                                                                                                                                                                                              |

## What happens when you run it

1) Download/extract package to `C:\Temp\Windows11Upgrade`.  

2) Generate `UpgradeConfig.ps1` with the parameter values.  

3) Run `Windows11Upgrade.ps1`: ISO download, hash check, mount, setup.exe, schedule reminders/post-reboot validation.  

4) Write state markers (`ScriptRunning.txt`, `PendingReboot.txt`) and log to `C:\Windows11UpgradeLog.txt`.  

5) Register reboot reminders and post-reboot validation to prompt users and verify after restart.

  

## RMM Task