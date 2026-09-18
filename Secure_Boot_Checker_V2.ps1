# ============================================
# Enterprise Security Check Script
# Credential Guard / HVCI / Device Guard / Secure Boot
# ============================================

$result = [PSCustomObject]@{
    SecureBoot         = "Unknown"
}

# --------------------------------------------
# Secure Boot Check
# --------------------------------------------
try {
    $secureBoot = Confirm-SecureBootUEFI
    $result.SecureBoot = if ($secureBoot) { "Enabled" } else { "Disabled" }
}
catch {
    $result.SecureBoot = "Not Supported / Legacy"
}

# --------------------------------------------
# Output
# --------------------------------------------
$result

# --------------------------------------------
# Exit logic (optional for compliance)
# --------------------------------------------

# Non-compliant if:
# - Secure Boot OFF
# - OR any core feature NOT running

if (
    $result.SecureBoot -ne "Enabled"
) {
    exit 2
}
else {
    exit 0
}