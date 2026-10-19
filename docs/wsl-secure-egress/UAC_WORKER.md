# Persistent Windows UAC worker

The `scripts/wsl-secure-egress/uac/` directory contains the project-owned persistent administrator bridge:

1. `Start-CorElevatedWorker.ps1` requests one Windows UAC approval through the built-in `sudo.exe --new-window` mode.
2. `Cor-UacWorker.ps1` stays resident in the elevated PowerShell window, restricts the job inbox to SYSTEM/Administrators, and adopts only GUID-named jobs from the user-writable staging directory.
3. `Submit-CorElevatedJob.ps1` submits an approved PowerShell job without requesting another UAC prompt.

The worker executes the full `COR-Full-AdminJob.ps1` only after the operator approves UAC. The worker does not modify CC Switch data and does not itself alter network policy until a job is submitted.

All three PowerShell files passed parser validation on 2026-10-19. A live resident worker cannot be claimed until the UAC dialog is accepted and `F:\Codex\uac-bridge\WORKER-READY.txt` is observed.