$ErrorActionPreference='Stop'

if (-not $env:COM60_CANDIDATE) { throw 'COM60_CANDIDATE missing' }
if (-not $env:COM60_DESKTOP) { throw 'COM60_DESKTOP missing' }
if (-not $env:COM60_PRODUCT_SHA) { throw 'COM60_PRODUCT_SHA missing' }
if (-not $env:COM60_LABEL) { throw 'COM60_LABEL missing' }
if (-not $env:COM60_PAGE_NAME) { throw 'COM60_PAGE_NAME missing' }

$outDir='secure-output/plain/screenshots'
$evDir='secure-output/plain/evidence'
$logDir='secure-output/plain/logs'
New-Item -ItemType Directory -Force -Path $outDir,$evDir,$logDir | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class COM60Win {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd,StringBuilder s,int n);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd,StringBuilder s,int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd,out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd,int cmd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  public class Info { public long H; public uint Pid; public string Title=""; public string ClassName=""; public int W; public int Height; public long Area; }
  public static List<Info> List(){
    var rows=new List<Info>();
    EnumWindows((h,l)=>{
      if(!IsWindowVisible(h))return true;
      uint pid; GetWindowThreadProcessId(h,out pid);
      var t=new StringBuilder(1024); GetWindowText(h,t,t.Capacity);
      var c=new StringBuilder(512); GetClassName(h,c,c.Capacity);
      RECT r; GetWindowRect(h,out r);
      int w=Math.Max(0,r.Right-r.Left), hh=Math.Max(0,r.Bottom-r.Top);
      rows.Add(new Info{H=h.ToInt64(),Pid=pid,Title=t.ToString(),ClassName=c.ToString(),W=w,Height=hh,Area=(long)w*hh});
      return true;
    },IntPtr.Zero);
    return rows;
  }
}
'@

$TeachingTitles=@('Collaborate and share','Design your report on mobile')

function Stop-PBI {
  Get-Process PBIDesktop -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-Process msmdsrv -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}
function Pbi-Windows {
  $pids=@(Get-Process PBIDesktop -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
  return @([COM60Win]::List() | Where-Object { $_.Pid -in $pids } | Sort-Object Area -Descending)
}
function Main-Window { return @(Pbi-Windows | Where-Object { $_.W -gt 800 -and $_.Height -gt 600 }) | Select-Object -First 1 }
function Secondary-Windows { return @(Pbi-Windows | Where-Object { $_.W -gt 180 -and $_.Height -gt 70 -and -not ($_.W -gt 800 -and $_.Height -gt 600) }) }
function Focus-Window($win) {
  [COM60Win]::ShowWindowAsync([intptr]$win.H,3) | Out-Null
  [COM60Win]::SetForegroundWindow([intptr]$win.H) | Out-Null
  Start-Sleep -Milliseconds 600
}
function Get-TeachingOverlays($main) {
  $rows=@()
  try {
    $root=[System.Windows.Automation.AutomationElement]::FromHandle([intptr]$main.H)
    if(-not $root){ return @() }
    $all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    foreach($el in $all){
      try { if($el.Current.Name -in $TeachingTitles){ $rows += $el } } catch {}
    }
  } catch {}
  return @($rows)
}
function Invoke-CloseButton($root) {
  try {
    $cond=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty,'Close')
    $button=$root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,$cond)
    if(-not $button -or $button.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button){ return $false }
    $pattern=$button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke(); return $true
  } catch { return $false }
}
function Dismiss-TeachingOverlays($main) {
  Focus-Window $main
  for($attempt=1;$attempt -le 30;$attempt++){
    $overlays=@(Get-TeachingOverlays $main)
    if($overlays.Count -eq 0){ return }
    foreach($overlay in $overlays){
      $node=$overlay; $closed=$false
      for($depth=0;$depth -lt 8;$depth++){
        try { $parent=[System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($node) } catch { $parent=$null }
        if(-not $parent){ break }
        if(Invoke-CloseButton $parent){ $closed=$true; break }
        $node=$parent
      }
      if(-not $closed){ [System.Windows.Forms.SendKeys]::SendWait('{ESC}') }
      Start-Sleep -Milliseconds 400
    }
    Start-Sleep -Seconds 1
  }
  $remaining=@(Get-TeachingOverlays $main | ForEach-Object {$_.Current.Name})
  if($remaining.Count -gt 0){ throw "teaching overlays remained: $($remaining -join ', ')" }
}
function Dismiss-CompatibleSecondary($win) {
  if(-not $win){ return $false }
  $title=[string]$win.Title
  $known=$title -match 'Report saved in an earlier version'
  $startupShape=($win.W -ge 500 -and $win.W -le 760 -and $win.Height -ge 160 -and $win.Height -le 420)
  if(-not ($known -or $startupShape)){ return $false }
  try {
    $root=[System.Windows.Automation.AutomationElement]::FromHandle([intptr]$win.H)
    if($root -and (Invoke-CloseButton $root)){ Start-Sleep -Seconds 2; return $true }
  } catch {}
  Focus-Window $win
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Seconds 2
  return $true
}
function Get-CanvasHash {
  $screen=[System.Windows.Forms.SystemInformation]::VirtualScreen
  $left=$screen.Left+55; $top=$screen.Top+250
  $width=[Math]::Min(1320,$screen.Width-80); $height=[Math]::Min(610,$screen.Height-290)
  if($width -le 0 -or $height -le 0){ throw 'invalid canvas crop' }
  $bmp=New-Object System.Drawing.Bitmap $width,$height
  $g=[System.Drawing.Graphics]::FromImage($bmp)
  $ms=New-Object System.IO.MemoryStream
  $sha=[System.Security.Cryptography.SHA256]::Create()
  try {
    $g.CopyFromScreen($left,$top,0,0,(New-Object System.Drawing.Size $width,$height))
    $bmp.Save($ms,[System.Drawing.Imaging.ImageFormat]::Png)
    return ([BitConverter]::ToString($sha.ComputeHash($ms.ToArray()))).Replace('-','').ToLowerInvariant()
  } finally { $sha.Dispose(); $ms.Dispose(); $g.Dispose(); $bmp.Dispose() }
}
function Capture-Screen([string]$path) {
  $b=[System.Windows.Forms.SystemInformation]::VirtualScreen
  $bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height
  $g=[System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen($b.Left,$b.Top,0,0,$b.Size)
    $bmp.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)
  } finally { $g.Dispose(); $bmp.Dispose() }
}

Stop-PBI
$pbix=(Resolve-Path -LiteralPath $env:COM60_CANDIDATE).Path
Start-Process -FilePath $env:COM60_DESKTOP -ArgumentList ('"{0}"' -f $pbix) | Out-Null
$main=$null
for($i=1;$i -le 60;$i++){
  Start-Sleep -Seconds 3
  $main=Main-Window
  $model=@(Get-Process msmdsrv -ErrorAction SilentlyContinue)
  if($main -and $model.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$main.Title) -and $main.Title -ne 'Untitled - Power BI Desktop'){ break }
}
if(-not $main){ throw 'Power BI main window never appeared' }
Focus-Window $main

for($round=1;$round -le 20;$round++){
  $secondary=@(Secondary-Windows)
  if($secondary.Count -eq 0){ break }
  $acted=$false
  foreach($win in $secondary){ if(Dismiss-CompatibleSecondary $win){ $acted=$true } }
  if(-not $acted){ Start-Sleep -Seconds 2 }
}
$main=Main-Window
if(-not $main){ throw 'Power BI main window disappeared' }
Dismiss-TeachingOverlays $main
Focus-Window $main
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')
[COM60Win]::SetCursorPos(10,10) | Out-Null
Start-Sleep -Seconds 2

$prev=$null; $stable=0
for($attempt=1;$attempt -le 90;$attempt++){
  $main=Main-Window
  if(-not $main){ $stable=0; Start-Sleep -Seconds 2; continue }
  $secondary=@(Secondary-Windows)
  foreach($win in $secondary){ Dismiss-CompatibleSecondary $win | Out-Null }
  $secondary=@(Secondary-Windows)
  if($secondary.Count -gt 0){ $stable=0; Start-Sleep -Seconds 2; continue }
  Dismiss-TeachingOverlays $main
  if(@(Get-TeachingOverlays $main).Count -gt 0){ $stable=0; Start-Sleep -Seconds 2; continue }
  $hash=Get-CanvasHash
  if($prev -and $hash -eq $prev){ $stable++ } else { $stable=0 }
  Add-Content -Encoding utf8 "$logDir/stability-$($env:COM60_LABEL).log" ("attempt={0}`tstable={1}`thash={2}" -f $attempt,$stable,$hash)
  if($stable -ge 6){ break }
  $prev=$hash
  Start-Sleep -Milliseconds 1700
}
if($stable -lt 6){ throw "canvas not stable for $($env:COM60_PAGE_NAME)" }
if(@(Secondary-Windows).Count -ne 0){ throw 'secondary Power BI window present at capture gate' }
if(@(Get-TeachingOverlays (Main-Window)).Count -ne 0){ throw 'teaching overlay present at capture gate' }

$png="$outDir/$($env:COM60_LABEL).png"
Capture-Screen $png
$img=[System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $png).Path)
try {
  if($img.Width -ne 1920 -or $img.Height -ne 1080){ throw "capture is $($img.Width)x$($img.Height), expected 1920x1080" }
} finally { $img.Dispose() }
$hash=(Get-FileHash -LiteralPath $png -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{
  ok=$true
  page=$env:COM60_PAGE_NAME
  label=$env:COM60_LABEL
  candidate_pbix_sha256=$env:COM60_PRODUCT_SHA
  native_width=1920
  native_height=1080
  screenshot_sha256=$hash
  stable_dialog_free=$true
  modal_rejected=$true
  teaching_overlays_rejected=$true
  canvas_stable=$true
}|ConvertTo-Json -Depth 5|Set-Content -Encoding utf8 "$evDir/page-$($env:COM60_LABEL).json"
Stop-PBI
