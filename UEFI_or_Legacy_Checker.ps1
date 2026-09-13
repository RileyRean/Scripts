Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Firmware {
    [DllImport("kernel32.dll")]
    public static extern bool GetFirmwareType(out uint firmwareType);
}
"@

[uint32]$type = 0
$result = [Firmware]::GetFirmwareType([ref]$type)

if ($result) {
    if ($type -eq 2) {
        Write-Output "UEFI detected (Compliant)"
        exit 0
    } elseif ($type -eq 1) {
        Write-Output "Legacy BIOS detected (Non-compliant)"
        exit 2
    } else {
        Write-Output "Unknown firmware type (Non-compliant)"
        exit 2
    }
} else {
    Write-Output "Failed to detect firmware type"
    exit 2
}