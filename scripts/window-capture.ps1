param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("list", "capture")]
    [string]$Action,

    [long]$WindowId = 0,
    [string]$Title,
    [switch]$ExactTitle,
    [string]$ProcessName,
    [switch]$Active,

    [ValidateSet("auto", "printWindow", "screen")]
    [string]$CaptureMode = "auto",

    [string]$OutputPath,
    [int]$MaxWidth = 0,
    [int]$MaxHeight = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

$nativeSource = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class SsMcpNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out RECT pvAttribute, int cbAttribute);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
"@

Add-Type -TypeDefinition $nativeSource

function Get-WindowTitle {
    param([IntPtr]$Handle)

    $length = [SsMcpNative]::GetWindowTextLength($Handle)
    if ($length -le 0) {
        return ""
    }

    $builder = New-Object System.Text.StringBuilder ($length + 1)
    [void][SsMcpNative]::GetWindowText($Handle, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Get-WindowProcessName {
    param([IntPtr]$Handle)

    $processId = 0
    [void][SsMcpNative]::GetWindowThreadProcessId($Handle, [ref]$processId)
    try {
        return ([System.Diagnostics.Process]::GetProcessById([int]$processId)).ProcessName
    }
    catch {
        return $null
    }
}

function Test-TitleMatch {
    param(
        [string]$Candidate,
        [string]$Needle,
        [bool]$RequireExact
    )

    if ([string]::IsNullOrWhiteSpace($Needle)) {
        return $true
    }

    if ($RequireExact) {
        return [string]::Equals($Candidate, $Needle, [System.StringComparison]::OrdinalIgnoreCase)
    }

    return $Candidate.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-WindowBounds {
    param([IntPtr]$Handle)

    $rect = New-Object SsMcpNative+RECT
    $rectSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][SsMcpNative+RECT])
    $dwmResult = [SsMcpNative]::DwmGetWindowAttribute($Handle, 9, [ref]$rect, $rectSize)

    if ($dwmResult -ne 0 -or $rect.Right -le $rect.Left -or $rect.Bottom -le $rect.Top) {
        $rect = New-Object SsMcpNative+RECT
        if (-not [SsMcpNative]::GetWindowRect($Handle, [ref]$rect)) {
            throw "Could not read window bounds for HWND $($Handle.ToInt64())."
        }
    }

    return [pscustomobject]@{
        left = $rect.Left
        top = $rect.Top
        right = $rect.Right
        bottom = $rect.Bottom
        width = $rect.Right - $rect.Left
        height = $rect.Bottom - $rect.Top
    }
}

function Get-VisibleWindows {
    $windows = New-Object System.Collections.Generic.List[object]
    $foreground = [SsMcpNative]::GetForegroundWindow()

    $callback = [SsMcpNative+EnumWindowsProc]{
        param([IntPtr]$Handle, [IntPtr]$Param)

        if (-not [SsMcpNative]::IsWindowVisible($Handle)) {
            return $true
        }

        $titleValue = Get-WindowTitle -Handle $Handle
        if ([string]::IsNullOrWhiteSpace($titleValue)) {
            return $true
        }

        try {
            $bounds = Get-WindowBounds -Handle $Handle
            if ($bounds.width -le 0 -or $bounds.height -le 0) {
                return $true
            }
        }
        catch {
            return $true
        }

        $processId = 0
        [void][SsMcpNative]::GetWindowThreadProcessId($Handle, [ref]$processId)
        $processNameValue = Get-WindowProcessName -Handle $Handle

        $windows.Add([pscustomobject]@{
            windowId = $Handle.ToInt64()
            title = $titleValue
            processId = [int]$processId
            processName = $processNameValue
            isActive = ($Handle -eq $foreground)
            bounds = $bounds
        })

        return $true
    }

    [void][SsMcpNative]::EnumWindows($callback, [IntPtr]::Zero)
    return $windows
}

function Find-TargetWindow {
    if ($Active) {
        $handle = [SsMcpNative]::GetForegroundWindow()
        if ($handle -eq [IntPtr]::Zero) {
            throw "There is no foreground window to capture."
        }
        return $handle
    }

    if ($WindowId -ne 0) {
        return [IntPtr]$WindowId
    }

    $windows = Get-VisibleWindows
    $candidates = @($windows)

    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $candidates = @($candidates | Where-Object { Test-TitleMatch -Candidate $_.title -Needle $Title -RequireExact $ExactTitle.IsPresent })
    }

    if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
        $candidates = @($candidates | Where-Object { $_.processName -ieq $ProcessName })
    }

    if ($candidates.Count -eq 0) {
        throw "No matching visible window was found."
    }

    return [IntPtr]$candidates[0].windowId
}

function Resize-BitmapIfNeeded {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [int]$MaxBitmapWidth,
        [int]$MaxBitmapHeight
    )

    $scale = 1.0
    if ($MaxBitmapWidth -gt 0 -and $Bitmap.Width -gt $MaxBitmapWidth) {
        $scale = [Math]::Min($scale, $MaxBitmapWidth / $Bitmap.Width)
    }
    if ($MaxBitmapHeight -gt 0 -and $Bitmap.Height -gt $MaxBitmapHeight) {
        $scale = [Math]::Min($scale, $MaxBitmapHeight / $Bitmap.Height)
    }

    if ($scale -ge 1.0) {
        return $Bitmap
    }

    $newWidth = [Math]::Max(1, [int][Math]::Round($Bitmap.Width * $scale))
    $newHeight = [Math]::Max(1, [int][Math]::Round($Bitmap.Height * $scale))
    $resized = New-Object System.Drawing.Bitmap $newWidth, $newHeight
    $graphics = [System.Drawing.Graphics]::FromImage($resized)
    try {
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.DrawImage($Bitmap, 0, 0, $newWidth, $newHeight)
    }
    finally {
        $graphics.Dispose()
        $Bitmap.Dispose()
    }

    return $resized
}

function Capture-Window {
    param([IntPtr]$Handle)

    $bounds = Get-WindowBounds -Handle $Handle
    if ($bounds.width -le 0 -or $bounds.height -le 0) {
        throw "Window bounds are empty for HWND $($Handle.ToInt64())."
    }

    $bitmap = New-Object System.Drawing.Bitmap $bounds.width, $bounds.height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $usedMode = $CaptureMode
    $printWindowSucceeded = $false

    if ($CaptureMode -eq "auto" -or $CaptureMode -eq "printWindow") {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $hdc = $graphics.GetHdc()
        try {
            $printWindowSucceeded = [SsMcpNative]::PrintWindow($Handle, $hdc, 2)
            if (-not $printWindowSucceeded) {
                $printWindowSucceeded = [SsMcpNative]::PrintWindow($Handle, $hdc, 0)
            }
        }
        finally {
            $graphics.ReleaseHdc($hdc)
            $graphics.Dispose()
        }

        if ($printWindowSucceeded) {
            $usedMode = "printWindow"
        }
        elseif ($CaptureMode -eq "printWindow") {
            $bitmap.Dispose()
            throw "PrintWindow failed for HWND $($Handle.ToInt64()). Try captureMode='screen'."
        }
    }

    if ($CaptureMode -eq "screen" -or ($CaptureMode -eq "auto" -and -not $printWindowSucceeded)) {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($bounds.left, $bounds.top, 0, 0, $bitmap.Size)
            $usedMode = "screen"
        }
        finally {
            $graphics.Dispose()
        }
    }

    $originalWidth = $bitmap.Width
    $originalHeight = $bitmap.Height
    $bitmap = Resize-BitmapIfNeeded -Bitmap $bitmap -MaxBitmapWidth $MaxWidth -MaxBitmapHeight $MaxHeight

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "ss-mcp-$([Guid]::NewGuid().ToString('N')).png")
    }

    $outputDirectory = [System.IO.Path]::GetDirectoryName($OutputPath)
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not [System.IO.Directory]::Exists($outputDirectory)) {
        [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    }

    $finalWidth = $bitmap.Width
    $finalHeight = $bitmap.Height
    try {
        $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }

    $titleValue = Get-WindowTitle -Handle $Handle
    $processNameValue = Get-WindowProcessName -Handle $Handle
    $processId = 0
    [void][SsMcpNative]::GetWindowThreadProcessId($Handle, [ref]$processId)

    return [pscustomobject]@{
        path = [System.IO.Path]::GetFullPath($OutputPath)
        mimeType = "image/png"
        width = $finalWidth
        height = $finalHeight
        originalWidth = $originalWidth
        originalHeight = $originalHeight
        captureMode = $usedMode
        window = [pscustomobject]@{
            windowId = $Handle.ToInt64()
            title = $titleValue
            processId = [int]$processId
            processName = $processNameValue
            bounds = $bounds
        }
    }
}

try {
    if ($Action -eq "list") {
        $windows = Get-VisibleWindows
        $filteredWindows = @($windows)

        if (-not [string]::IsNullOrWhiteSpace($Title)) {
            $filteredWindows = @($filteredWindows | Where-Object { Test-TitleMatch -Candidate $_.title -Needle $Title -RequireExact $false })
        }
        if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
            $filteredWindows = @($filteredWindows | Where-Object { $_.processName -ieq $ProcessName })
        }

        [pscustomobject]@{
            windows = @($filteredWindows)
        } | ConvertTo-Json -Depth 8 -Compress
        exit 0
    }

    $handle = Find-TargetWindow
    Capture-Window -Handle $handle | ConvertTo-Json -Depth 8 -Compress
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
