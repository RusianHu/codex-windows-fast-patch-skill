[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DesktopExe,
    [Parameter(Mandatory=$true)][string]$ExpectedPackageFullName,
    [Parameter(Mandatory=$true)][ValidatePattern('^http://127\.0\.0\.1:\d+$')][string]$ProxyUrl
)
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class CodexProxyPackageIdentity {
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode)]
  public static extern int GetCurrentPackageFullName(ref uint length, StringBuilder name);
  public static string Read() {
    uint length=0;
    int result=GetCurrentPackageFullName(ref length,null);
    if(result!=122)throw new InvalidOperationException("Package identity unavailable: "+result);
    var name=new StringBuilder((int)length);
    result=GetCurrentPackageFullName(ref length,name);
    if(result!=0)throw new InvalidOperationException("Package identity read failed: "+result);
    return name.ToString();
  }
}
'@
if([CodexProxyPackageIdentity]::Read() -ne $ExpectedPackageFullName){throw 'Package identity does not match the requested Codex package.'}
if(-not(Test-Path -LiteralPath $DesktopExe -PathType Leaf)){throw 'Codex Desktop executable is missing.'}
$env:HTTP_PROXY=$ProxyUrl
$env:HTTPS_PROXY=$ProxyUrl
$env:ALL_PROXY=$ProxyUrl
$env:WS_PROXY=$ProxyUrl
$env:WSS_PROXY=$ProxyUrl
$env:NO_PROXY='localhost,127.0.0.1,::1'
$env:NODE_USE_ENV_PROXY='1'
$env:ELECTRON_GET_USE_PROXY='1'
$arguments="--proxy-server=$ProxyUrl --proxy-bypass-list=localhost;127.0.0.1;[::1] --disable-quic"
$desktop=Start-Process -FilePath $DesktopExe -ArgumentList $arguments -PassThru
[ordered]@{package=$ExpectedPackageFullName;rootPid=$desktop.Id;helperPid=$PID;time=(Get-Date).ToString('o');proxyEnvironmentSetInPackage=$true}|
    ConvertTo-Json|Set-Content -LiteralPath (Join-Path $env:USERPROFILE '.codex\last-proxy-launch.json') -Encoding UTF8
