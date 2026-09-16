# PowerShell Scripts for Microsoft Intune & Endpoint Management

A collection of PowerShell tools developed for practical Microsoft Intune, Windows endpoint-management, and Secure Boot troubleshooting scenarios.

These scripts were created to address operational gaps that can appear in real environments, particularly around:

- Secure Boot and UEFI readiness
- Secure Boot certificate and key troubleshooting
- Detection and remediation workflows for Intune
- Reliable removal of applications that update themselves and change MSI product codes
- Endpoint health and operational checks

Several scripts in this repository have been tested and used in production after controlled validation. Always test in a lab or pilot deployment before using any script in your own production environment.

> **Important:** Some scripts are detection-only and safe to run for assessment. Others can remove software, modify endpoint configuration, or require restarts. Read the script, understand its scope, and test before deployment.

---

## Repository contents

| Script | Purpose | Type | Production status |
|---|---|---|---|
| `Experimental_Secure_Boot_Issue_Checker.ps1` | Detects Secure Boot, UEFI, certificate/key, and related readiness issues. Designed to produce automation-friendly output without boolean-output issues. | Detection | Production tested |
| `SecureBoot_Remediation_AllInOne_v3.4_FullReadable.ps1` | Performs Secure Boot diagnostics and remediation actions for supported scenarios. Intended to pair with the Secure Boot issue checker. | Remediation | Production tested |
| `UEFI_CA_2023_Checker.ps1` | Checks readiness/status related to the 2023 UEFI CA and Secure Boot certificate updates. | Detection | Production tested |
| `UEFI_or_Legacy_Checker.ps1` | Identifies whether a Windows device is using UEFI or Legacy BIOS boot mode. | Detection | Production tested |
| `Device_Uptime_Checker - 1.0.ps1` | Reports Windows uptime, last boot time, and current system time. | Reporting | Production tested |
| `DTU_Dynamic-Target-Uninstaller_V1.ps1` | Dynamically detects and removes targeted applications without relying only on a fixed MSI product code. | Remediation | Production tested |

---

## Secure Boot workflow

The Secure Boot scripts are designed around a detection-and-remediation approach that fits Microsoft Intune operational patterns.

### 1. Detect

Use the following scripts to identify device state and determine whether remediation is needed:

- `UEFI_or_Legacy_Checker.ps1`
- `UEFI_CA_2023_Checker.ps1`
- `Experimental_Secure_Boot_Issue_Checker.ps1`

`Experimental_Secure_Boot_Issue_Checker.ps1` was created to avoid a previous output-validity issue caused by boolean values. Its output is intended to be more reliable for automation, parsing, and endpoint-management workflows.

### 2. Remediate

Use:

- `SecureBoot_Remediation_AllInOne_v3.4_FullReadable.ps1`

This script is intended for devices identified by the detection stage. Because Secure Boot remediation can involve higher-risk actions, including configuration and boot-related changes, it should be deployed only after validation against the target hardware, firmware, Windows version, and security baseline.

### Recommended deployment approach

1. Test on non-production devices representing each OEM/model/firmware family.
2. Run detection scripts first and collect output.
3. Scope remediation only to affected devices.
4. Pilot remediation with a small device group.
5. Monitor reboot behavior, BitLocker recovery events, boot state, and remediation logs.
6. Expand deployment only after pilot validation.

---

## Dynamic Target Uninstaller (DTU)

### The problem

Applications that update automatically can change their MSI product code between versions. In a managed environment, this can lead to many installed versions across hundreds of devices.

A static Intune uninstall command may work for one version but fail for newer or older versions when the product code changes. This creates unnecessary operational work:

- Hunting MSI product codes
- Creating multiple uninstall assignments
- Managing version-specific cleanup
- Dealing with partially removed or problematic application versions

### The approach

`DTU_Dynamic-Target-Uninstaller_V1.ps1` is designed to dynamically identify and remove a targeted application rather than depending only on one fixed product code.

This makes it useful for:

- Removing software that has auto-updated across a fleet
- Cleaning up multiple installed versions
- Responding to problematic application versions
- Removing unwanted applications during device preparation or rebuild workflows
- Reducing manual MSI product-code discovery and maintenance

### DTU V3 roadmap

A newer DTU V3 version is currently in testing and is **not production validated yet**.

Planned/implemented capabilities being tested include:

- Optional targeting of specific devices without creating a dedicated Intune group
- Optional multi-application uninstall capability
- More flexible cleanup scenarios for newly provisioned or freshly rebuilt systems
- Better support for responding to widespread unwanted-app, bug, or cleanup events

Until production validation is complete, V3 should be treated as a test/beta version and used only in lab or controlled pilot environments.

---

## Device uptime checker

`Device_Uptime_Checker - 1.0.ps1` provides a lightweight way to report:

- Last boot time
- Current system time
- Device uptime in days, hours, minutes, and seconds

Possible uses include reboot-compliance checks, patching validation, troubleshooting, and general endpoint-health reporting.

---

## Intended use

These scripts are intended for:

- Microsoft Intune administrators
- Endpoint-management engineers
- Microsoft 365 administrators
- Windows systems administrators
- Security and compliance teams
- Homelab testing and learning environments

They may be useful as standalone PowerShell tools, Intune PowerShell scripts, Proactive Remediations, or components of a wider endpoint-management workflow.

---

## Safety and testing

Before using these scripts:

- Review the source code and understand every action.
- Test in a lab or isolated pilot group.
- Verify compatibility with your Windows version, BIOS/UEFI firmware, OEM hardware, and endpoint-security tooling.
- Back up critical data and ensure BitLocker recovery keys are accessible before Secure Boot or boot-related remediation.
- Do not deploy destructive remediation scripts broadly without staged validation.
- Adapt logging, exit codes, output formatting, and targeting to your organization’s operational standards.

The repository contains practical tooling, not a universal one-click deployment package. Each organization has different device models, firmware configurations, application packaging, security controls, and change-management requirements.

---

## Development approach

These tools were built through a requirements-driven engineering process:

1. Identify a real operational or management problem.
2. Define the desired logic, flow, and safeguards.
3. Use AI-assisted development to accelerate initial implementation.
4. Review, refine, and adapt the code to real endpoint behavior.
5. Test repeatedly in controlled conditions.
6. Validate production-ready versions before operational deployment.

AI was used as an implementation accelerator, while requirements definition, validation, refinement, testing, and production ownership remain part of the engineering work.

---

## Contributions and feedback

Feedback, issue reports, improvements, and testing results are welcome.

If you adapt a script for another endpoint-management platform or hardware environment, please test carefully and share findings where possible.
