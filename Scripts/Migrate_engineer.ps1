$OldUserName = "$env:COMPUTERNAME\engineer"
$NewUserName = "WHC\wcengineer"

. (Join-Path "$PSScriptRoot" 'ScanState_Win7.ps1') "$OldUserName"

. (Join-Path "$PSScriptRoot" 'LoadState_Helper.ps1') "$OldUserName" "$NewUserName"
