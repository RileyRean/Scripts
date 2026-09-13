<#
Intune Remediations Detection Script
Name     : UEFI_CA2023_Detection.ps1
Purpose  : Detect whether Secure Boot DB contains "Windows UEFI CA 2023"
Exit     : 0 = Present / OK
           1 = Missing or unable to verify
Context  : Run as SYSTEM, 64-bit PowerShell
#>

$ErrorActionPreference = "Stop"
$Present = $false

function Test-BytePattern {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [Parameter(Mandatory = $true)]
        [byte[]]$Pattern
    )

    if (-not $Bytes -or -not $Pattern) { return $false }
    if ($Pattern.Length -gt $Bytes.Length) { return $false }

    for ($i = 0; $i -le ($Bytes.Length - $Pattern.Length); $i++) {
        $Match = $true

        for ($j = 0; $j -lt $Pattern.Length; $j++) {
            if ($Bytes[$i + $j] -ne $Pattern[$j]) {
                $Match = $false
                break
            }
        }

        if ($Match) { return $true }
    }

    return $false
}

try {
    if (-not (Get-Command -Name Get-SecureBootUEFI -ErrorAction SilentlyContinue)) {
        throw "Get-SecureBootUEFI cmdlet not available."
    }

    $DbEntry = Get-SecureBootUEFI -Name db -ErrorAction Stop

    if (-not $DbEntry -or -not $DbEntry.Bytes) {
        throw "Secure Boot DB empty or unreadable."
    }

    $SearchText = "Windows UEFI CA 2023"

    $AsciiPattern   = [System.Text.Encoding]::ASCII.GetBytes($SearchText)
    $UnicodePattern = [System.Text.Encoding]::Unicode.GetBytes($SearchText)

    if (
        (Test-BytePattern -Bytes $DbEntry.Bytes -Pattern $AsciiPattern) -or
        (Test-BytePattern -Bytes $DbEntry.Bytes -Pattern $UnicodePattern)
    ) {
        $Present = $true
    }

    Write-Output "WindowsUefiCA2023Present=$Present"

    if ($Present -eq $true) {
        exit 0
    }
    else {
        exit 1
    }
}
catch {
    Write-Output "WindowsUefiCA2023Present=False"
    Write-Output "Error=$($_.Exception.Message)"
    exit 1
}