$global:LocalUSMTPath = 'C:\USMT'
if (-not(Test-Path "$LocalUSMTPath")) {
	Write-Host "Creating directory '$LocalUSMTPath'"
	New-Item -Path "$LocalUSMTPath" -ItemType Directory
}

$global:RemoteUSMTPath = '\\files.nerdygriffin.net\programfiles\USMT'

$global:MigStorePath = (Join-Path (Join-Path $RemoteUSMTPath "MigStore") $env:COMPUTERNAME)
if (-not(Test-Path "$MigStorePath")) {
	Write-Host "Creating directory '$MigStorePath'"
	New-Item -Path "$MigStorePath" -ItemType Directory
}

$global:LocalExecutablePath = (Join-Path $LocalUSMTPath 'amd64')
if (-not((Test-Path "$LocalExecutablePath\loadstate.exe") -and (Test-Path "$LocalExecutablePath\savestate.exe"))) {
	$RemoteExecutablePath = (Join-Path $RemoteUSMTPath 'amd64')
	Write-Host "Copying '$RemoteExecutablePath' to '$LocalExecutablePath'"
	Copy-Item -Path "$RemoteExecutablePath" -Destination "$LocalUSMTPath" -Force -Recurse
}

$global:LocalScriptPath = (Join-Path $LocalUSMTPath 'Scripts')
# if (-not(Test-Path "$LocalScriptPath")) {
$RemoteScriptPath = (Join-Path $RemoteUSMTPath 'Scripts')
Write-Host "Copying '$RemoteScriptPath' to '$LocalScriptPath'"
Copy-Item -Path "$RemoteScriptPath" -Destination "$LocalUSMTPath" -Force -Recurse
# }

$global:ConfigPath = (Join-Path "$MigStorePath" 'Config.xml')
