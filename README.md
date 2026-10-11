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

  This hash corresponds to the validated driver build `5.32.908.2026`. If the hardware or driver hash differs, the script stops before sending the private status query.

## Run

1. Connect the adapter directly to the PC.
2. Close any other adapter diagnostic utility while collecting the report. The driver uses a shared diagnostic buffer.
3. Open **Windows PowerShell** with **Run as administrator**.
4. From the repository root, run:

   ```powershell
   Set-Location "."
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

The script does not collect Wi-Fi SSIDs or passwords. The PnP ID and interface GUID identify this adapter; redact them before posting the report publicly if you prefer.

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
