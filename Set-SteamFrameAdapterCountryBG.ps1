#Requires -Version 5.1
<#
.SYNOPSIS
    Review or explicitly submit a one-time BG country-code request to the
    validated Valve Steam Frame Wireless Adapter driver.

.DESCRIPTION
    Default mode is preview-only: it prints the exact vendor request bytes and
    does not call the driver. Use -Apply only after reviewing this file.

    The BG variant is experimental. The source protocol this is based on only
    implements and verifies US. This script sends one BG request at most, then
    reports the driver's reply and queried state. It does not modify the .sys,
    INF, registry, device setup region, Wi-Fi profiles, or headset settings.

.PARAMETER Apply
    Send the one-time BG request after strict adapter, service, and driver-hash
    checks. Requires an elevated PowerShell session.

MIT License notice for the adapted vendor-protocol framing:
Copyright (c) 2026 toorux
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

[CmdletBinding()]
param(
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$expectedPnpPattern = 'USB\VID_28DE&PID_2432\*'
$expectedService = 'rtwlanuval'
$expectedDriverVersion = '5.32.908.2026'
$expectedDriverHash = '378ffaee3b782b9a7f5382c294a846e7c4b3b952717991fd1fd93795c5a85612'
$driverFile = Join-Path $env:windir 'System32\drivers\rtwlanuval.sys'

# Vendor command layout from the reviewed source:
# OID 0xff818040; command words [0, 0, 29, 3]; 16-byte NUL-padded tokens "67" and "BG".
$body = New-Object byte[] 336
[Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]0), 0, $body, 0, 4)
[Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]0), 0, $body, 4, 4)
[Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]29), 0, $body, 8, 4)
[Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]3), 0, $body, 12, 4)
[Buffer]::BlockCopy([Text.Encoding]::ASCII.GetBytes('67'), 0, $body, 16, 2)
[Buffer]::BlockCopy([Text.Encoding]::ASCII.GetBytes('BG'), 0, $body, 32, 2)

function New-VendorPacket {
    param(
        [Parameter(Mandatory)][uint32]$Oid,
        [Parameter(Mandatory)][byte[]]$Body
    )
    $n = [uint32]$Body.Length
    $headerMagic = [Convert]::ToUInt32('814CE000', 16)
    $header = New-Object 'System.UInt32[]' 10
    $header[0] = [uint32]($n + 36)
    $header[1] = $headerMagic
    $header[2] = 4
    $header[3] = 1
    $header[4] = 7
    $header[5] = [uint32]($n + 40)
    $header[6] = $Oid
    $header[7] = [uint32]($n + 24)
    $header[8] = [uint32]($n + 24)
    $header[9] = $n
    $packet = New-Object byte[] (40 + $Body.Length)
    for ($i = 0; $i -lt $header.Length; $i++) {
        [Buffer]::BlockCopy([BitConverter]::GetBytes($header[$i]), 0, $packet, 4 * $i, 4)
    }
    [Buffer]::BlockCopy($Body, 0, $packet, 40, $Body.Length)
    return ,$packet
}

$oid = [Convert]::ToUInt32('FF818040', 16)
$packet = New-VendorPacket -Oid $oid -Body $body
$bodyHex = [BitConverter]::ToString($body)
$packetHeaderHex = [BitConverter]::ToString($packet, 0, 40)

Write-Output 'Steam Frame Wireless Adapter - BG one-shot request review'
Write-Output 'Mode: PREVIEW ONLY (no driver request is sent unless -Apply is supplied)'
Write-Output ("Target PNP ID pattern: {0}" -f $expectedPnpPattern)
Write-Output ("Expected service: {0}" -f $expectedService)
Write-Output ("Expected driver version: {0}" -f $expectedDriverVersion)
Write-Output ("Expected driver SHA256: {0}" -f $expectedDriverHash)
Write-Output 'Control type: wlan_ihv_control_type_driver (1)'
Write-Output 'OID: 0xFF818040'
Write-Output 'Inner command DWORDs: 0, 0, 29, 3'
Write-Output 'Tokens: ASCII "67" and ASCII "BG", each in a 16-byte zero-padded slot'
Write-Output 'BG bytes: 42 47'
Write-Output ("Inner body length: {0} bytes" -f $body.Length)
Write-Output ("Outer packet length: {0} bytes" -f $packet.Length)
Write-Output ("Outer 40-byte header: {0}" -f $packetHeaderHex)
Write-Output ("Inner body, hex: {0}" -f $bodyHex)

if (-not $Apply) {
    Write-Output ''
    Write-Output 'Preview complete. Nothing was sent and no system state was changed.'
    Write-Output 'The BG command is experimental; the reviewed source only verifies the US variant.'
    Write-Output 'Do not add -Apply until the payload and risk are reviewed.'
    return
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Apply requires an elevated PowerShell session. No driver request was sent.'
}

$adapters = @(Get-CimInstance Win32_NetworkAdapter | Where-Object {
    $_.PNPDeviceID -like $expectedPnpPattern -and $_.ServiceName -eq $expectedService -and $_.GUID
})
if ($adapters.Count -ne 1) {
    throw ("Expected exactly one matching Valve adapter; found {0}. No driver request was sent." -f $adapters.Count)
}
$adapter = $adapters[0]

if (-not (Test-Path -LiteralPath $driverFile -PathType Leaf)) {
    throw 'Expected driver file is missing. No driver request was sent.'
}
$actualHash = (Get-FileHash -LiteralPath $driverFile -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedDriverHash) {
    throw ("Driver SHA256 {0} does not match the reviewed build. No driver request was sent." -f $actualHash)
}
$signedDriver = Get-CimInstance Win32_PnPSignedDriver | Where-Object {
    $_.DeviceID -like $expectedPnpPattern
} | Select-Object -First 1
if (-not $signedDriver -or $signedDriver.DriverVersion -ne $expectedDriverVersion) {
    throw 'Driver version does not match the reviewed build. No driver request was sent.'
}
$driverService = Get-CimInstance Win32_SystemDriver -Filter "Name='$expectedService'"
if (-not $driverService -or $driverService.State -ne 'Running') {
    throw 'Valve adapter driver service is not running. No driver request was sent.'
}

Write-Output ''
Write-Output ("Matched adapter: {0}" -f $adapter.Name)
Write-Output ("Interface GUID: {0}" -f $adapter.GUID)
Write-Output 'The BG setter is not validated by the reviewed source. It will be submitted once only.'

if (-not ('SteamFrameBgSetterV1' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class SteamFrameBgResult
{
    public string BeforeCountry { get; set; }
    public string BeforeInfo { get; set; }
    public string DriverReply { get; set; }
    public string AfterCountry { get; set; }
    public string AfterInfo { get; set; }
    public string AfterCountryHex { get; set; }
    public bool Verified { get; set; }
}

public static class SteamFrameBgSetterV1
{
    private const uint DriverControl = 1;
    private const uint OidCountry = 0xff81521f;
    private const uint OidInfo = 0xff818040;
    private const uint OidDone = 0xff818041;
    private const uint OidOutput = 0xff818042;
    private const string MutexName = @"Global\SteamFrameLabOriginalDriverDiagnosticV1";

    [DllImport("wlanapi.dll", ExactSpelling = true)]
    private static extern uint WlanOpenHandle(uint clientVersion, IntPtr reserved, out uint negotiatedVersion, out IntPtr clientHandle);
    [DllImport("wlanapi.dll", ExactSpelling = true)]
    private static extern uint WlanCloseHandle(IntPtr clientHandle, IntPtr reserved);
    [DllImport("wlanapi.dll", ExactSpelling = true)]
    private static extern uint WlanIhvControl(IntPtr clientHandle, ref Guid interfaceGuid, uint type,
        uint inBufferSize, [In] byte[] inBuffer, uint outBufferSize, [In, Out] byte[] outBuffer, out uint bytesReturned);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr CreateMutexW(IntPtr securityAttributes, bool initialOwner, string name);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern bool ReleaseMutex(IntPtr handle);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern void SetLastError(uint error);

    private static void PutU32(byte[] b, int offset, uint value)
    {
        Buffer.BlockCopy(BitConverter.GetBytes(value), 0, b, offset, 4);
    }
    private static uint GetU32(byte[] b, int offset)
    {
        if (offset < 0 || offset + 4 > b.Length) throw new InvalidOperationException("Truncated response field.");
        return BitConverter.ToUInt32(b, offset);
    }
    private static byte[] Packet(uint oid, byte[] body)
    {
        uint n = (uint)body.Length;
        uint[] header = { n + 36, 0x814ce000, 4, 1, 7, n + 40, oid, n + 24, n + 24, n };
        byte[] packet = new byte[40 + body.Length];
        for (int i = 0; i < header.Length; i++) PutU32(packet, i * 4, header[i]);
        Buffer.BlockCopy(body, 0, packet, 40, body.Length);
        return packet;
    }
    private static byte[] Decode(byte[] request, byte[] response, uint returned)
    {
        if (response.Length != request.Length || returned < 40 || returned > response.Length)
            throw new InvalidOperationException("Invalid response length.");
        for (int i = 0; i < 28; i++) if (request[i] != response[i]) throw new InvalidOperationException("Protocol header mismatch.");
        for (int i = 36; i < 40; i++) if (request[i] != response[i]) throw new InvalidOperationException("Protocol size mismatch.");
        uint written = GetU32(response, 28);
        if (GetU32(response, 32) != 0 || written > GetU32(response, 36) || 40UL + written > returned)
            throw new InvalidOperationException("Driver did not confirm a valid response size.");
        byte[] payload = new byte[(int)written];
        Buffer.BlockCopy(response, 40, payload, 0, (int)written);
        return payload;
    }
    private static byte[] Exchange(IntPtr handle, Guid guid, uint oid, byte[] body)
    {
        byte[] request = Packet(oid, body);
        byte[] response = (byte[])request.Clone();
        uint returned;
        uint error = WlanIhvControl(handle, ref guid, DriverControl, (uint)request.Length, request,
            (uint)response.Length, response, out returned);
        if (error != 0) throw new InvalidOperationException("WlanIhvControl returned Windows error " + error + ".");
        return Decode(request, response, returned);
    }
    private static byte[] EmptyBody() { return new byte[300]; }
    private static byte[] CountryBytes(IntPtr handle, Guid guid)
    {
        return Exchange(handle, guid, OidCountry, EmptyBody());
    }
    private static string CountryText(byte[] b)
    {
        if (b.Length == 2 && b[0] == 0 && b[1] == 0) return "UNKNOWN (00 00)";
        if (b.Length != 2 || b[0] < 32 || b[0] > 126 || b[1] < 32 || b[1] > 126)
            throw new InvalidOperationException("Invalid country-code payload: " + BitConverter.ToString(b));
        return Encoding.ASCII.GetString(b);
    }
    private static byte[] InfoBody()
    {
        byte[] b = new byte[336];
        PutU32(b, 0, 0); PutU32(b, 4, 0); PutU32(b, 8, 0); PutU32(b, 12, 3);
        string[] tokens = { "echo", "core", "6g_info" };
        for (int i = 0; i < tokens.Length; i++)
        {
            byte[] token = Encoding.ASCII.GetBytes(tokens[i]);
            Buffer.BlockCopy(token, 0, b, 16 + 16 * i, token.Length);
        }
        return b;
    }
    private static bool IsDone(IntPtr handle, Guid guid)
    {
        byte[] b = Exchange(handle, guid, OidDone, EmptyBody());
        if (b.Length != 4 || GetU32(b, 0) > 1) throw new InvalidOperationException("Invalid driver completion flag.");
        return GetU32(b, 0) == 1;
    }
    private static string ReadInfo(IntPtr handle, Guid guid)
    {
        IsDone(handle, guid);
        Exchange(handle, guid, OidInfo, InfoBody());
        bool completed = false;
        for (int i = 0; i < 20; i++)
        {
            Thread.Sleep(100);
            if (IsDone(handle, guid)) { completed = true; break; }
        }
        if (!completed) throw new TimeoutException("Driver status query timed out; it was not resubmitted.");

        List<byte> output = new List<byte>();
        uint? sequence = null;
        for (int i = 0; i < 64; i++)
        {
            byte[] b = Exchange(handle, guid, OidOutput, EmptyBody());
            if (b.Length < 16) throw new InvalidOperationException("Invalid output block.");
            uint mode = GetU32(b, 0), status = GetU32(b, 4), currentSequence = GetU32(b, 8), len = GetU32(b, 12);
            if (mode != 0 || (status != 0 && status != 2) || len > 200 || b.Length != 16 + len)
                throw new InvalidOperationException("Invalid driver output block.");
            if (sequence.HasValue && sequence.Value != currentSequence)
                throw new InvalidOperationException("Driver output changed during query; another diagnostic may be active.");
            sequence = currentSequence;
            for (int j = 0; j < len; j++) output.Add(b[16 + j]);
            int nul = output.IndexOf(0);
            if (nul >= 0) { output.RemoveRange(nul, output.Count - nul); break; }
            if (status == 0) break;
            if (i == 63) throw new InvalidOperationException("Driver output exceeded the read limit.");
        }
        foreach (byte value in output) if (value > 127) throw new InvalidOperationException("Driver output was not ASCII.");
        return Encoding.ASCII.GetString(output.ToArray()).Replace("\r", "");
    }
    private static string ReadStatus(IntPtr handle, Guid guid)
    {
        string info = ReadInfo(handle, guid);
        if (info.IndexOf("6G Info", StringComparison.Ordinal) < 0)
            throw new InvalidOperationException("Unexpected driver response: 6G Info marker not found.");
        return info;
    }
    private static byte[] ManualBgBody()
    {
        byte[] b = new byte[336];
        PutU32(b, 0, 0); PutU32(b, 4, 0); PutU32(b, 8, 29); PutU32(b, 12, 3);
        Buffer.BlockCopy(Encoding.ASCII.GetBytes("67"), 0, b, 16, 2);
        Buffer.BlockCopy(Encoding.ASCII.GetBytes("BG"), 0, b, 32, 2);
        return b;
    }
    private static string SubmitBgOnce(IntPtr handle, Guid guid)
    {
        IsDone(handle, guid);
        Exchange(handle, guid, OidInfo, ManualBgBody()); // One submission; never retry this command.
        bool completed = false;
        for (int i = 0; i < 20; i++)
        {
            Thread.Sleep(100);
            if (IsDone(handle, guid)) { completed = true; break; }
        }
        if (!completed) throw new TimeoutException("BG request timed out; it was not resubmitted. State may be uncertain.");

        List<byte> output = new List<byte>();
        uint? sequence = null;
        for (int i = 0; i < 64; i++)
        {
            byte[] b = Exchange(handle, guid, OidOutput, EmptyBody());
            if (b.Length < 16) throw new InvalidOperationException("Invalid setter output block.");
            uint mode = GetU32(b, 0), status = GetU32(b, 4), currentSequence = GetU32(b, 8), len = GetU32(b, 12);
            if (mode != 0 || (status != 0 && status != 2) || len > 200 || b.Length != 16 + len)
                throw new InvalidOperationException("Invalid setter output format.");
            if (sequence.HasValue && sequence.Value != currentSequence)
                throw new InvalidOperationException("Setter output changed; another diagnostic may be active.");
            sequence = currentSequence;
            for (int j = 0; j < len; j++) output.Add(b[16 + j]);
            int nul = output.IndexOf(0);
            if (nul >= 0) { output.RemoveRange(nul, output.Count - nul); break; }
            if (status == 0) break;
            if (i == 63) throw new InvalidOperationException("Setter output exceeded the read limit.");
        }
        foreach (byte value in output) if (value > 127) throw new InvalidOperationException("Setter reply was not ASCII.");
        return Encoding.ASCII.GetString(output.ToArray()).Replace("\r", "");
    }
    private static bool Has6GSupport(string info)
    {
        foreach (string raw in info.Split('\n'))
        {
            string line = raw.Trim();
            if (line.StartsWith("6G Support (domain:", StringComparison.Ordinal) &&
                !line.Contains("domain:00") && !line.Contains("REGU_RSN_DEFAULT")) return true;
        }
        return false;
    }
    public static SteamFrameBgResult ApplyOnce(string guidText)
    {
        SetLastError(0);
        IntPtr mutex = CreateMutexW(IntPtr.Zero, true, MutexName);
        if (mutex == IntPtr.Zero) throw new InvalidOperationException("Could not create adapter diagnostic lock.");
        if (Marshal.GetLastWin32Error() == 183)
        {
            CloseHandle(mutex);
            throw new InvalidOperationException("Another adapter diagnostic is active. No BG request was sent.");
        }
        try
        {
            Guid guid = new Guid(guidText);
            uint negotiated;
            IntPtr client;
            uint openError = WlanOpenHandle(2, IntPtr.Zero, out negotiated, out client);
            if (openError != 0) throw new InvalidOperationException("WlanOpenHandle returned Windows error " + openError + ".");
            try
            {
                byte[] beforeBytes = CountryBytes(client, guid);
                string beforeCountry = CountryText(beforeBytes);
                string beforeInfo = ReadStatus(client, guid);
                if (beforeCountry == "BG" && Has6GSupport(beforeInfo))
                    return new SteamFrameBgResult { BeforeCountry = beforeCountry, BeforeInfo = beforeInfo,
                        DriverReply = "Already BG with 6 GHz support; no setter sent.",
                        AfterCountry = beforeCountry, AfterInfo = beforeInfo,
                        AfterCountryHex = BitConverter.ToString(beforeBytes), Verified = true };
                if (beforeCountry != "UNKNOWN (00 00)")
                    throw new InvalidOperationException("Current country is " + beforeCountry + ", not UNKNOWN (00 00); no BG setter sent.");

                string reply = SubmitBgOnce(client, guid);
                byte[] afterBytes = CountryBytes(client, guid);
                string afterCountry = CountryText(afterBytes);
                string afterInfo = ReadStatus(client, guid);
                bool ack = reply.IndexOf("Country code has changed to BG", StringComparison.OrdinalIgnoreCase) >= 0;
                bool verified = ack && afterCountry == "BG" && Has6GSupport(afterInfo);
                return new SteamFrameBgResult { BeforeCountry = beforeCountry, BeforeInfo = beforeInfo,
                    DriverReply = reply, AfterCountry = afterCountry, AfterInfo = afterInfo,
                    AfterCountryHex = BitConverter.ToString(afterBytes), Verified = verified };
            }
            finally { WlanCloseHandle(client, IntPtr.Zero); }
        }
        finally
        {
            ReleaseMutex(mutex);
            CloseHandle(mutex);
        }
    }
}
'@
}

$result = [SteamFrameBgSetterV1]::ApplyOnce([string]$adapter.GUID)
Write-Output ''
Write-Output '[Before]'
Write-Output ("Country: {0}" -f $result.BeforeCountry)
Write-Output $result.BeforeInfo
Write-Output ''
Write-Output '[Driver reply]'
Write-Output $result.DriverReply
Write-Output ''
Write-Output '[After]'
Write-Output ("Country: {0}" -f $result.AfterCountry)
Write-Output ("Country payload hex: {0}" -f $result.AfterCountryHex)
Write-Output $result.AfterInfo
if ($result.Verified) {
    Write-Output 'Verification: BG acknowledged; driver reports BG and 6 GHz support.'
} else {
    Write-Warning 'BG was not fully verified. The command was not repeated. Replug/restart the adapter before any further attempt.'
}
