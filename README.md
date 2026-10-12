# Steam Frame Wireless Adapter Status Check

A small Windows PowerShell collector for the Valve Steam Frame Wireless Adapter. It reads the adapter driver's current country code and its reported 6 GHz status, then saves a text report beside the script.

The collector does **not** set a country code or change adapter, Wi-Fi, or firewall settings. It submits a fixed status query through the Windows WLAN IHV driver-control API and reads the response. Because this asks the driver to produce its diagnostic response, the report describes the state returned at query time; it is not a passive capture and does not prove that pairing or streaming works.

## Requirements

- Windows 10 or Windows 11, using Windows PowerShell 5.1.
- The Valve USB adapter connected to the PC.
- PowerShell opened with **Run as administrator**.
- The adapter must be `USB\VID_28DE&PID_2432`, use service `rtwlanuval`, and have the currently validated driver file SHA256:

  ```text
  378ffaee3b782b9a7f5382c294a846e7c4b3b952717991fd1fd93795c5a85612
  ```

  This hash corresponds to the validated driver build `5.32.908.2026`. If the hardware or driver hash differs, the script stops before sending the status query.

## Run

1. Connect the adapter directly to the PC.
2. Close any other adapter diagnostic utility while collecting the report. The driver uses a shared diagnostic buffer.
3. Open **Windows PowerShell** with **Run as administrator**.
4. From the repository root, run:

   ```powershell
   .\Collect-SteamFrameAdapterStatus.ps1
   ```

5. If PowerShell blocks local scripts, allow scripts only in this PowerShell process, then run the script again:

   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\Collect-SteamFrameAdapterStatus.ps1
   ```

   This process-scoped setting ends when the PowerShell window closes. It does not change the machine or user execution policy. If an organization policy prevents this, do not try to override it.

The script prints the report and writes a timestamped file beside itself:

```text
SteamFrame-adapter-status-YYYYMMDD-HHMMSS.txt
```

## What the report contains

- Windows edition, version, build, and architecture.
- Adapter name, PnP ID, interface GUID, driver service and version, and driver SHA256.
- The country code returned by the adapter driver, including the raw response bytes.
- The driver's raw `6G Info` status text.

The script does not collect Wi-Fi SSIDs or passwords. Reports include device-specific identifiers such as the adapter instance ID and interface GUID. Review a report before sharing it; generated reports are ignored by Git by default.

## Reading the 6 GHz result

- `Country: BG` means the driver returned the two ASCII bytes `42-47` (`BG`).
- `6G Support (domain:06)` means the driver reported 6 GHz support at the time of the query.
- `6G NOT Support` or `UNKNOWN (00 00)` records the unavailable/unknown status returned by the driver at that time.
- A supported 6 GHz status does not establish that Steam Frame pairing, Remote Play, or streaming will succeed. Keep the raw status text and timestamp with any support report.

## Safety and limitations

- The script contains no command to set `US`, `BG`, or another regulatory region.
- It checks the exact hardware ID, driver service, and SHA256 before sending a vendor-specific query.
- It sends a country-status request and the fixed `echo core 6g_info` diagnostic request, then reads the driver's completion/output buffers. It does not install software or contact a network service.
- The underlying driver is proprietary. The script cannot prove whether the driver's status query internally refreshes its diagnostic state; treat the result as the status returned during the query.
- It does not diagnose the headset's SteamOS state, Steam/SteamVR pairing, firewall rules, or the reason a streaming session may remain in `Waiting`.

The fixed query protocol is based on publicly available MIT-licensed source material. Attribution and the license notice are included at the top of the PowerShell script.

Windows API reference: [WlanIhvControl](https://learn.microsoft.com/en-us/windows/win32/api/wlanapi/nf-wlanapi-wlanihvcontrol).

## Experimental BG country-code request

`Set-SteamFrameAdapterCountryBG.ps1` is a separate experimental script. It sends a one-time vendor-specific request to the Valve adapter driver to set its reported country code to `BG` (Bulgaria). It does not change the Steam Frame's SteamOS regulatory domain, Windows' device setup region, the adapter's registry settings, or the driver files.

The request format is adapted from publicly available source code whose implemented and verified setter is for `US`. The `BG` variant is not validated or supported by Valve or by that source project. Use it only if you understand this limitation and the regulatory requirements where the adapter is being used. The script is restricted to the Valve adapter hardware ID and exact driver build listed below; it stops if those checks do not match.

### Preview the request

From the repository root, run this first. Preview mode prints the request fields and bytes but does not contact the driver or change adapter state:

```powershell
.\Set-SteamFrameAdapterCountryBG.ps1
```

### Apply the request once

Only if you intend to run the experimental request, open **Windows PowerShell** with **Run as administrator**, then run:

```powershell
.\Set-SteamFrameAdapterCountryBG.ps1 -Apply
```

If PowerShell blocks local scripts, allow scripts only in that PowerShell process, then rerun the command:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Set-SteamFrameAdapterCountryBG.ps1 -Apply
```

The script checks the adapter PnP ID, service, driver version, driver file hash, and running service before applying. It also takes a diagnostic mutex so it will not run alongside this repository's collector. It sends the BG request at most once per run, and only if the driver's current country query returns `UNKNOWN (00 00)`. If the adapter already reports BG with 6 GHz support, it sends no setter request. If the current country is anything else, it stops. After submission, it reads the driver's reply and status; it does not automatically retry an unverified request.

An elevated session is required for `-Apply`. Preview mode does not require elevation. A driver version or hash mismatch, an unexpected before-state, or another active diagnostic makes the script stop before submitting the BG request. The driver can still reject a request after it has been sent; in that case the script reports the failure and does not automatically resend it.

### What success means

`Verification: BG acknowledged; driver reports BG and 6 GHz support.` means the driver acknowledged the request and its immediate follow-up queries returned BG and 6 GHz support. It does not prove that the headset will pair or stream, and it does not establish that the setting survives a PC reboot, adapter reconnect, or driver restart. Run `Collect-SteamFrameAdapterStatus.ps1` after a reboot and **before** applying again to capture whether the state persisted.

A reported one-time test completed successfully and the Steam Frame connected afterward. Repeatability and persistence across reboot have not been established.

The script does not patch or replace the `.sys`/INF files, change registry values, create a startup task, or configure a rollback. It changes the adapter driver's reported country state through a vendor-specific control request; the persistence behavior is not established. Do not run it repeatedly to force a result. If verification fails, follow the script's message and collect a fresh read-only status report before another attempt.
