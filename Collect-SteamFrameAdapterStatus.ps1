# Read-only status collector for the Valve Steam Frame USB wireless adapter.
# The fixed driver query sequence and its response decoder are adapted from
# MIT-licensed public source code (Copyright (c) 2026 toorux).
# This script only requests Country and `echo core 6g_info`; it never sends a
# country/regulatory-setting command.
#
# MIT License
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

$ErrorActionPreference = 'Stop'

$expectedHash = '378ffaee3b782b9a7f5382c294a846e7c4b3b952717991fd1fd93795c5a85612'
$driverServiceName = 'rtwlanuval'
$driverFile = Join-Path $env:windir 'System32\drivers\rtwlanuval.sys'
$reportPath = Join-Path $PSScriptRoot ("SteamFrame-adapter-status-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$lines = New-Object 'System.Collections.Generic.List[string]'

$lines.Add('Steam Frame Wireless Adapter - Windows read-only status report')
$lines.Add(('Collected: {0:yyyy-MM-dd HH:mm:ss zzz}' -f (Get-Date)))
$lines.Add('')

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open PowerShell with Run as administrator, then run this script again.'
    }

    $os = Get-CimInstance Win32_OperatingSystem
    $lines.Add('[Windows]')
    $lines.Add(('Edition: {0}' -f $os.Caption))
    $lines.Add(('Version / build: {0} / {1}' -f $os.Version, $os.BuildNumber))
    $lines.Add(('Architecture: {0}' -f $os.OSArchitecture))
    $lines.Add('')

    $devices = @(Get-CimInstance Win32_NetworkAdapter | Where-Object {
        $_.PNPDeviceID -like 'USB\VID_28DE&PID_2432\*' -and
        $_.ServiceName -eq $driverServiceName -and
        $_.GUID
    })
    if ($devices.Count -ne 1) {
        throw ("Expected exactly one Valve adapter (USB\VID_28DE&PID_2432, service {0}); found {1}. No driver query was sent." -f $driverServiceName, $devices.Count)
    }
    $device = $devices[0]

    if (-not (Test-Path -LiteralPath $driverFile -PathType Leaf)) {
        throw "Driver file not found at $driverFile. No driver query was sent."
    }
    $hash = (Get-FileHash -LiteralPath $driverFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $expectedHash) {
        throw ("Driver SHA256 is {0}, not the expected validated build. For safety, no private driver query was sent." -f $hash)
    }

    $signedDriver = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceID -eq $device.PNPDeviceID } | Select-Object -First 1
    $driverService = Get-CimInstance Win32_SystemDriver -Filter "Name='$driverServiceName'"

    $lines.Add('[Adapter / driver]')
    $lines.Add(('Name: {0}' -f $device.Name))
    $lines.Add(('PNP ID: {0}' -f $device.PNPDeviceID))
    $lines.Add(('Network interface GUID: {0}' -f $device.GUID))
    $lines.Add(('Service: {0}' -f $device.ServiceName))
    if ($signedDriver) {
        $lines.Add(('Driver version: {0}' -f $signedDriver.DriverVersion))
        $lines.Add(('Driver date: {0}' -f $signedDriver.DriverDate))
        $lines.Add(('Driver provider: {0}' -f $signedDriver.DriverProviderName))
        $lines.Add(('INF: {0}' -f $signedDriver.InfName))
    }
    if ($driverService) { $lines.Add(('Service state: {0}' -f $driverService.State)) }
    $lines.Add(('Driver SHA256: {0}' -f $hash))
    $lines.Add('')

    if (-not ('SteamFrameReadOnlyStatus' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public sealed class SteamFrameStatusResult
{
    public string Country { get; set; }
    public string CountryPayloadHex { get; set; }
    public string Info { get; set; }
}

public static class SteamFrameReadOnlyStatus
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
        byte[] x = BitConverter.GetBytes(value);
        Buffer.BlockCopy(x, 0, b, offset, 4);
    }
    private static uint GetU32(byte[] b, int offset)
    {
        if (offset < 0 || offset + 4 > b.Length) throw new InvalidOperationException("Truncated response field.");
        return BitConverter.ToUInt32(b, offset);
    }
    private static byte[] Packet(uint oid, byte[] body)
    {
        uint n = (uint)body.Length;
        byte[] packet = new byte[40 + body.Length];
        uint[] header = { n + 36, 0x814ce000, 4, 1, 7, n + 40, oid, n + 24, n + 24, n };
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
    private static byte[] EmptyBody()
    {
        return new byte[300];
    }
    private static bool IsDone(IntPtr handle, Guid guid)
    {
        byte[] b = Exchange(handle, guid, OidDone, EmptyBody());
        if (b.Length != 4 || GetU32(b, 0) > 1) throw new InvalidOperationException("Invalid driver completion flag.");
        return GetU32(b, 0) == 1;
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
    private static string ReadInfo(IntPtr handle, Guid guid)
    {
        IsDone(handle, guid); // Drain old completion state; submit the read-only query once.
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
    public static SteamFrameStatusResult Query(string guidText)
    {
        SetLastError(0);
        IntPtr mutex = CreateMutexW(IntPtr.Zero, true, MutexName);
        if (mutex == IntPtr.Zero) throw new InvalidOperationException("Could not create diagnostic lock (Win32 " + Marshal.GetLastWin32Error() + ").");
        if (Marshal.GetLastWin32Error() == 183)
        {
            CloseHandle(mutex);
            throw new InvalidOperationException("Another adapter diagnostic is active. Close it and retry later.");
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
                byte[] country = Exchange(client, guid, OidCountry, EmptyBody());
                string countryText = country.Length == 2 && country[0] >= 32 && country[0] <= 126 && country[1] >= 32 && country[1] <= 126
                    ? Encoding.ASCII.GetString(country)
                    : (country.Length == 2 && country[0] == 0 && country[1] == 0 ? "UNKNOWN (00 00)" : "INVALID");
                string info = ReadInfo(client, guid);
                if (info.IndexOf("6G Info", StringComparison.Ordinal) < 0)
                    throw new InvalidOperationException("Unexpected driver response: 6G Info marker not found.");
                return new SteamFrameStatusResult {
                    Country = countryText,
                    CountryPayloadHex = BitConverter.ToString(country),
                    Info = info
                };
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

    $result = [SteamFrameReadOnlyStatus]::Query([string]$device.GUID)
    $lines.Add('[Adapter-reported regulatory / 6 GHz status]')
    $lines.Add(('Country: {0}' -f $result.Country))
    $lines.Add(('Country payload hex: {0}' -f $result.CountryPayloadHex))
    $lines.Add($result.Info.TrimEnd())
    $lines.Add('')
}
catch {
    $lines.Add('[Collection error]')
    $lines.Add($_.Exception.Message)
}

$report = $lines -join [Environment]::NewLine
Set-Content -LiteralPath $reportPath -Value $report -Encoding UTF8
Write-Output $report
Write-Output ''
Write-Output ("Report saved to: {0}" -f $reportPath)
