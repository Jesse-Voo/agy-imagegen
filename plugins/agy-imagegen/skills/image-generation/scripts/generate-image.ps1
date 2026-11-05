<#
.SYNOPSIS
  Generates an image with Gemini (Antigravity CLI, "agy") or OpenAI (Codex CLI) and saves it to disk.

.DESCRIPTION
  Three modes:

    Generate  (default)   Runs the chosen backend headlessly, waits for the image, saves it.
    -FromFile <path>      Skips generation: takes an image another tool already made (for
                          example agy's or Codex's built-in image tool) and saves it to
                          OutputPath / the default folder, converting format if needed.
    -Check                Prints which backends are installed and exits.

  Backends (-Backend, or env IMAGEGEN_BACKEND; default agy):
    agy    agy -p ... --output-format json. agy's image tool writes under
           <brain>\<conversation_id>\; the id is read from the JSON output.
    codex  codex exec ... in a scratch folder, asking Codex's built-in $imagegen
           (gpt-image-2) to save the file there. Falls back to the newest file under
           $CODEX_HOME\generated_images.

  Neither backend is run with a permission bypass: the script itself does the copying.
  The final saved path is printed as the last line of stdout.

.PARAMETER Description
  What the image should depict.

.PARAMETER OutputPath
  Optional. File path (.png, .jpg/.jpeg, .bmp, .gif) or an existing folder. If omitted, the
  file is named <timestamp>-<description-slug>.png in the default folder.

.PARAMETER Backend
  agy | codex.

.PARAMETER FromFile
  Path of an already-generated image to save (no generation).

.PARAMETER Check
  Report which backends are available.

.PARAMETER TimeoutSeconds
  Give up after this many seconds. Default 300.

.NOTES
  ENVIRONMENT (all optional):
    IMAGEGEN_BACKEND  Default backend: agy or codex.
    AGY_EXE           Full path to agy.exe. Default: agy on PATH, else %LOCALAPPDATA%\agy\bin\agy.exe
    AGY_BRAIN_DIR     agy's conversation folder. Default: ~\.gemini\antigravity-cli\brain
    CODEX_EXE         Full path to the codex executable. Default: codex on PATH
    CODEX_HOME        Codex's home folder. Default: ~\.codex
    AGY_IMAGE_DIR     Default save folder. Default: <Pictures>\Generated

.EXAMPLE
  .\generate-image.ps1 -Check
.EXAMPLE
  .\generate-image.ps1 -Description "a red fox in a snowy forest, watercolor style"
.EXAMPLE
  .\generate-image.ps1 -Backend codex -Description "a red fox, watercolor" -OutputPath "$HOME\Pictures\fox.png"
.EXAMPLE
  .\generate-image.ps1 -FromFile "C:\path\to\generated.jpg" -Description "a red fox" -OutputPath "$HOME\Pictures\fox.png"
#>
param(
    [string]$Description,
    [string]$OutputPath,
    [ValidateSet("agy", "codex")]
    [string]$Backend,
    [string]$FromFile,
    [switch]$Check,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

# --- Locating the backends -----------------------------------------------------------
function Find-Agy {
    if ($env:AGY_EXE) { if (Test-Path $env:AGY_EXE) { return $env:AGY_EXE } else { return $null } }
    $cmd = Get-Command agy -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:LOCALAPPDATA "agy\bin\agy.exe"
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Find-Codex {
    if ($env:CODEX_EXE) { if (Test-Path $env:CODEX_EXE) { return $env:CODEX_EXE } else { return $null } }
    # npm installs codex.ps1 + codex.cmd shims; Start-Process needs an executable, so prefer .exe/.cmd.
    $all = @(Get-Command codex -All -ErrorAction SilentlyContinue)
    $pick = $all | Where-Object { $_.Source -match '\.(exe|cmd|bat)$' } | Select-Object -First 1
    if ($pick) { return $pick.Source }
    return $null
}

if ($Check) {
    $a = Find-Agy
    $c = Find-Codex
    "agy:   " + $(if ($a) { "available ($a)" } else { "not found" })
    "codex: " + $(if ($c) { "available ($c)" } else { "not found" })
    $def = if ($env:IMAGEGEN_BACKEND) { $env:IMAGEGEN_BACKEND } else { "agy" }
    "default backend: $def"
    return
}

if (-not $FromFile -and -not $Description) {
    Write-Error "Provide -Description (or -FromFile, or -Check)."
    exit 1
}

if (-not $Backend) { $Backend = if ($env:IMAGEGEN_BACKEND) { $env:IMAGEGEN_BACKEND.ToLower() } else { "agy" } }
if ($Backend -notin "agy", "codex") {
    Write-Error "Unknown backend '$Backend'. Use agy or codex."
    exit 1
}

# --- Resolve where the image will go -------------------------------------------------
$DefaultDir = if ($env:AGY_IMAGE_DIR) { $env:AGY_IMAGE_DIR } else { Join-Path ([Environment]::GetFolderPath("MyPictures")) "Generated" }

if (-not $OutputPath -or (Test-Path $OutputPath -PathType Container)) {
    $dir  = if ($OutputPath) { $OutputPath } else { $DefaultDir }
    $label = if ($Description) { $Description } elseif ($FromFile) { [System.IO.Path]::GetFileNameWithoutExtension($FromFile) } else { "image" }
    $slug = ($label.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    if (-not $slug) { $slug = "image" }
    $OutputPath = Join-Path $dir ("{0}-{1}.png" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $slug)
}

$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outDir = Split-Path $OutputPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# --- Shared helpers ------------------------------------------------------------------
function Save-Image([string]$Source, [string]$Destination) {
    $srcExt = [System.IO.Path]::GetExtension($Source).ToLower().TrimStart('.')
    $dstExt = [System.IO.Path]::GetExtension($Destination).ToLower().TrimStart('.')
    $jpg = @('jpg', 'jpeg')
    $same = ($srcExt -eq $dstExt) -or (($srcExt -in $jpg) -and ($dstExt -in $jpg))

    if ($same -or -not $dstExt) {
        Copy-Item $Source $Destination -Force
        return
    }

    Add-Type -AssemblyName System.Drawing
    $format = switch ($dstExt) {
        'png'  { [System.Drawing.Imaging.ImageFormat]::Png }
        'bmp'  { [System.Drawing.Imaging.ImageFormat]::Bmp }
        'gif'  { [System.Drawing.Imaging.ImageFormat]::Gif }
        { $_ -in 'jpg', 'jpeg' } { [System.Drawing.Imaging.ImageFormat]::Jpeg }
        default { $null }
    }
    if (-not $format) {
        Write-Error "Cannot convert to .$dstExt (webp is not a supported output). Source image kept at $Source"
        exit 1
    }
    $img = [System.Drawing.Image]::FromFile($Source)
    try { $img.Save($Destination, $format) } finally { $img.Dispose() }
}

# Start-Process does not quote array elements, so quote the prompt ourselves.
function Quote-Arg([string]$Text) { '"' + ($Text -replace '"', '\"') + '"' }

function Wait-ForImage([string[]]$Dirs, [datetime]$Since, [switch]$Recurse) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        foreach ($d in $Dirs) {
            if (-not (Test-Path $d)) { continue }
            $found = Get-ChildItem $d -File -Recurse:$Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '^\.(png|jpe?g|webp)$' -and $_.LastWriteTime -ge $Since } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($found) { Start-Sleep -Milliseconds 500; return $found }
        }
        Start-Sleep -Seconds 2
    }
    return $null
}

$workDir = Join-Path $env:TEMP "agy-imagegen"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# --- Mode: save an existing image ----------------------------------------------------
if ($FromFile) {
    if (-not (Test-Path $FromFile -PathType Leaf)) { Write-Error "File not found: $FromFile"; exit 1 }
    Save-Image (Resolve-Path $FromFile).Path $OutputPath
    Write-Output $OutputPath
    return
}

# --- Backend: agy (Gemini) -----------------------------------------------------------
function Invoke-Agy {
    $exe = Find-Agy
    if (-not $exe) { Write-Error "agy not found. Install the Antigravity CLI or set AGY_EXE."; exit 1 }
    $brain = if ($env:AGY_BRAIN_DIR) { $env:AGY_BRAIN_DIR } else { Join-Path $env:USERPROFILE ".gemini\antigravity-cli\brain" }

    $stdout = Join-Path $workDir "agy-stdout.json"
    $stderr = Join-Path $workDir "agy-stderr.txt"
    Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

    # --disable-slash-commands: don't let this agy session load the image-generation skill
    # itself (that would recurse into the skill and then stall on a denied shell command).
    $started = Get-Date
    $proc = Start-Process -FilePath $exe `
        -ArgumentList @("--disable-slash-commands", "-p", (Quote-Arg ("Call your built-in image generation tool right now to generate an image of $Description. " + "Do not read any files or skills and do not run any commands. Just generate the image.")), "--output-format", "json") `
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

    # agy replies before its image subagent always finishes, so poll the conversation folder.
    $image = Wait-ForImage @((Join-Path $brain $result.conversation_id)) $started.AddSeconds(-5)
    if (-not $image) { Write-Error "No image appeared for agy conversation $($result.conversation_id). agy said: $($result.response)"; exit 1 }
    return $image
}

# --- Backend: codex (OpenAI gpt-image-2 via the built-in $imagegen skill) -------------
function Invoke-Codex {
    $exe = Find-Codex
    if (-not $exe) { Write-Error "codex not found. Install the Codex CLI (npm i -g @openai/codex), sign in, or set CODEX_EXE."; exit 1 }
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }

    # A scratch workspace Codex is allowed to write into (workspace-write sandbox).
    $scratch = Join-Path $workDir ("codex-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null

    $prompt = 'Use the $imagegen skill to generate an image of ' + $Description +
        '. Use only $imagegen for this; do not use any other skill or run any other helper. Save the final image as image.png in the current working directory, then reply with only the file name.'

    $stdout = Join-Path $scratch "codex-stdout.txt"
    $stderr = Join-Path $scratch "codex-stderr.txt"

    $started = Get-Date
    $proc = Start-Process -FilePath $exe `
        -ArgumentList @("exec", "--skip-git-repo-check", "--sandbox", "workspace-write", (Quote-Arg $prompt)) `
        -WorkingDirectory $scratch -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Write-Error "codex timed out after $TimeoutSeconds seconds."
        exit 1
    }

    # Preferred: the file Codex was told to save here. Fallback: Codex's own generated_images store.
    $image = Wait-ForImage @($scratch) $started.AddSeconds(-5)
    if (-not $image) { $image = Wait-ForImage @((Join-Path $codexHome "generated_images")) $started.AddSeconds(-5) -Recurse }
    if (-not $image) {
        $err = if (Test-Path $stderr) { (Get-Content $stderr -Raw) } else { "" }
        $out = if (Test-Path $stdout) { (Get-Content $stdout -Raw) } else { "" }
        Write-Error "No image produced by codex (exit $($proc.ExitCode)). stdout: $out stderr: $err"
        exit 1
    }
    return $image
}

# --- Run ----------------------------------------------------------------------------
$image = if ($Backend -eq "codex") { Invoke-Codex } else { Invoke-Agy }
Save-Image $image.FullName $OutputPath
Write-Output $OutputPath
