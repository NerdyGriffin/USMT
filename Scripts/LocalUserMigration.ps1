$OldUserName = $args[0]
$NewUserName = $args[1]

# Clear Mark-of-the-Web from every script in this folder up front, so dot-sourced
# dependencies (e.g. CloneUSMT.ps1) are not left blocked under MOTW.
Get-ChildItem -Path "$PSScriptRoot" -Filter '*.ps1' -Recurse | Unblock-File

. (Join-Path "$PSScriptRoot" 'ScanState_Win10.ps1') "$OldUserName"

. (Join-Path "$PSScriptRoot" 'LoadState_Helper.ps1') "$OldUserName" "$NewUserName"
