<#
.SYNOPSIS
  Generates an image with the Antigravity CLI (agy) and saves it to disk.

.DESCRIPTION
  Runs agy headlessly (-p, no window, no --dangerously-skip-permissions). agy's built-in
  image tool saves the result under <brain>\<conversation_id>\; this script reads the
  conversation id from agy's JSON output, waits for the image, then copies it to
  OutputPath itself (converting format if the extension differs from what agy produced).
  Prints the final saved path as the last line of stdout.

.PARAMETER Description
  What the image should depict.

.PARAMETER OutputPath
  Optional. Where to save the image (.png, .jpg/.jpeg, .bmp or .gif). If omitted, or if it
  is an existing folder, the file is named <timestamp>-<description-slug>.png and saved in
  the default folder (see ENVIRONMENT).

.PARAMETER TimeoutSeconds
  Give up after this many seconds. Default 300.

.NOTES
  ENVIRONMENT (all optional):
    AGY_EXE        Full path to agy.exe. Default: agy on PATH, else %LOCALAPPDATA%\agy\bin\agy.exe
    AGY_BRAIN_DIR  agy's conversation folder. Default: ~\.gemini\antigravity-cli\brain
    AGY_IMAGE_DIR  Default save folder. Default: <Pictures>\Generated

.EXAMPLE
  .\generate-image.ps1 -Description "a red fox in a snowy forest, watercolor style"
.EXAMPLE
  .\generate-image.ps1 -Description "a red fox, watercolor" -OutputPath "$HOME\Pictures\fox.png"
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Description,

    [string]$OutputPath,

    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

# --- Locate agy and its output folders -----------------------------------------------
$AgyExe = $env:AGY_EXE
if (-not $AgyExe) {
    $cmd = Get-Command agy -ErrorAction SilentlyContinue
    $AgyExe = if ($cmd) { $cmd.Source } else { Join-Path $env:LOCALAPPDATA "agy\bin\agy.exe" }
}
if (-not (Test-Path $AgyExe)) {
    Write-Error "agy not found at '$AgyExe'. Install the Antigravity CLI or set AGY_EXE."
    exit 1
}

$BrainDir = if ($env:AGY_BRAIN_DIR) { $env:AGY_BRAIN_DIR } else { Join-Path $env:USERPROFILE ".gemini\antigravity-cli\brain" }
$DefaultDir = if ($env:AGY_IMAGE_DIR) { $env:AGY_IMAGE_DIR } else { Join-Path ([Environment]::GetFolderPath("MyPictures")) "Generated" }

# --- Resolve where the image will go -------------------------------------------------
if (-not $OutputPath -or (Test-Path $OutputPath -PathType Container)) {
    $dir  = if ($OutputPath) { $OutputPath } else { $DefaultDir }
    $slug = ($Description.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    if (-not $slug) { $slug = "image" }
    $OutputPath = Join-Path $dir ("{0}-{1}.png" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $slug)
}

$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# --- Run agy headlessly --------------------------------------------------------------
$prompt = "Generate an image of $Description"

# Run from a scratch dir so agy doesn't treat some random cwd as its workspace.
$workDir = Join-Path $env:TEMP "agy-imagegen"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

$stdout = Join-Path $workDir "stdout.json"
$stderr = Join-Path $workDir "stderr.txt"
Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

# Start-Process does not quote array elements, so quote the prompt ourselves.
$quoted = '"' + ($prompt -replace '"', '\"') + '"'
$proc = Start-Process -FilePath $AgyExe `
    -ArgumentList @("-p", $quoted, "--output-format", "json") `
    -WorkingDirectory $workDir -NoNewWindow -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr

if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Write-Error "agy timed out after $TimeoutSeconds seconds."
    exit 1
}

$raw = if (Test-Path $stdout) { Get-Content $stdout -Raw } else { "" }
try { $result = $raw | ConvertFrom-Json } catch { $result = $null }

if (-not $result -or -not $result.conversation_id) {
    $err = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { "" }
    Write-Error "agy returned no usable JSON (exit $($proc.ExitCode)). stdout: $raw stderr: $err"
    exit 1
}

# --- Wait for the image, then copy / convert it --------------------------------------
# agy replies before its image subagent always finishes, so poll the conversation folder.
$convDir = Join-Path $BrainDir $result.conversation_id
$image = $null
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $convDir) {
        $image = Get-ChildItem $convDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(png|jpe?g|webp)$' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($image) { break }
    }
    Start-Sleep -Seconds 2
}

if (-not $image) {
    Write-Error "No image appeared in $convDir. agy said: $($result.response)"
    exit 1
}
Start-Sleep -Milliseconds 500  # let the file finish flushing

$srcExt = $image.Extension.ToLower().TrimStart('.')
$dstExt = [System.IO.Path]::GetExtension($OutputPath).ToLower().TrimStart('.')
$sameFormat = ($srcExt -eq $dstExt) -or (($srcExt -eq 'jpg' -or $srcExt -eq 'jpeg') -and ($dstExt -eq 'jpg' -or $dstExt -eq 'jpeg'))

if ($sameFormat -or -not $dstExt) {
    Copy-Item $image.FullName $OutputPath -Force
} else {
    Add-Type -AssemblyName System.Drawing
    $format = switch ($dstExt) {
        'png'  { [System.Drawing.Imaging.ImageFormat]::Png }
        'bmp'  { [System.Drawing.Imaging.ImageFormat]::Bmp }
        'gif'  { [System.Drawing.Imaging.ImageFormat]::Gif }
        { $_ -in 'jpg','jpeg' } { [System.Drawing.Imaging.ImageFormat]::Jpeg }
        default { $null }
    }
    if (-not $format) {
        Write-Error "Cannot convert to .$dstExt (webp is not a supported output). Source image kept at $($image.FullName)"
        exit 1
    }
    $img = [System.Drawing.Image]::FromFile($image.FullName)
    try { $img.Save($OutputPath, $format) } finally { $img.Dispose() }
}

Write-Output $OutputPath
