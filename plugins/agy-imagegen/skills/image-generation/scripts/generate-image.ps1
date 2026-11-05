<#
.SYNOPSIS
  Generates images with Gemini (Antigravity CLI or Gemini API), OpenAI (Images API), Pollinations
  (free, no key) or a local OpenAI-compatible image server, and saves them to disk.

.DESCRIPTION
  Modes:

    Generate  (default)   Runs the chosen backend, waits for the image, saves it.
    -FromFile <path>      Skips generation: takes an image another tool already made (for
                          example agy's built-in image tool) and saves it to OutputPath / the
                          default folder, converting format if needed.
    -Check                Prints which backends are available and exits.
    -Login / -Logout      Saves / removes an API key (see -Provider).

  Backends (-Backend, or env IMAGEGEN_BACKEND; default agy):
    agy           agy -p ... --output-format json (Gemini via your Antigravity sign-in).
    gemini        Gemini API with a Google AI Studio key. Gemini image models (default
                  gemini-2.5-flash-image) and Imagen (-Model imagen-4.0-generate-001).
    openai        OpenAI Images API with an OpenAI API key (default model gpt-image-2;
                  also gpt-image-1, gpt-image-1-mini, dall-e-3 ...).
    pollinations  Free public image service, no key and no account (default model flux).
                  No reference images.
    local         A local OpenAI-compatible image server at IMAGEGEN_LOCAL_URL.
    auto          Picks one of the enabled, available backends based on the request.
                  "Enabled" = IMAGEGEN_BACKENDS (comma list); default is every available
                  backend (pollinations only when listed there).

  Bulk:       -Count N makes N variations of -Description; -BatchFile <txt> makes one image per
              non-empty line. Several images get -01, -02 ... suffixes. Results print one path per line.
  References: -Reference "a.png|b.jpg" passes existing images to the model as inspiration/input
              (agy, gemini with Gemini models, openai, local).

  No backend is run with a permission bypass: the script itself does the copying.
  The saved path(s) are printed as the last line(s) of stdout; the backend used goes to stderr.

.PARAMETER Description
  What the image should depict.

.PARAMETER OutputPath
  Optional. File path (.png, .jpg/.jpeg, .bmp, .gif) or a folder. If omitted, files are named
  <timestamp>-<description-slug>.png in the default folder.

.PARAMETER Backend
  agy | gemini | openai | pollinations | local | auto.

.PARAMETER Model
  Optional model name for gemini, openai, pollinations or local (overrides the env defaults).

.PARAMETER Count
  Number of variations to generate of -Description (default 1, max 10).

.PARAMETER BatchFile
  Text file with one description per line (blank lines and lines starting with # are skipped).

.PARAMETER Reference
  One or more existing image files (separate with |) to use as reference/inspiration.

.PARAMETER FromFile
  Path of an already-generated image to save (no generation).

.PARAMETER Check
  Report which backends are available.

.PARAMETER Login
  Save an API key for -Provider (hidden prompt, or one line on stdin). The key is verified, then
  stored encrypted with Windows DPAPI for this Windows user only.

.PARAMETER Logout
  Remove the saved key for -Provider.

.PARAMETER Provider
  openai (default) or gemini. Used with -Login / -Logout.

.PARAMETER TimeoutSeconds
  Give up on each image after this many seconds. Default 300.

.NOTES
  ENVIRONMENT (all optional):
    IMAGEGEN_BACKEND       Default backend.
    IMAGEGEN_BACKENDS      Backends the AI may choose from with auto, e.g. "agy,openai,pollinations".
    AGY_EXE                Full path to agy.exe. Default: agy on PATH, else %LOCALAPPDATA%\agy\bin\agy.exe
    AGY_BRAIN_DIR          agy's conversation folder. Default: ~\.gemini\antigravity-cli\brain
    OPENAI_API_KEY         OpenAI key (overrides a saved -Login key).
    OPENAI_BASE_URL        Default https://api.openai.com/v1
    OPENAI_IMAGE_MODEL     Default gpt-image-2
    GEMINI_API_KEY         Google AI Studio key (or GOOGLE_API_KEY; overrides a saved -Login key).
    GEMINI_IMAGE_MODEL     Default gemini-2.5-flash-image
    POLLINATIONS_MODEL     Default flux
    IMAGEGEN_LOCAL_URL     Base URL of a local OpenAI-compatible image server; enables the local backend.
    IMAGEGEN_LOCAL_MODEL   Model name to send to the local server (optional).
    AGY_IMAGE_DIR          Default save folder. Default: <Pictures>\Generated

.EXAMPLE
  .\generate-image.ps1 -Check
.EXAMPLE
  .\generate-image.ps1 -Description "a red fox in a snowy forest, watercolor style"
.EXAMPLE
  .\generate-image.ps1 -Backend pollinations -Description "a flat vector coffee logo"
.EXAMPLE
  .\generate-image.ps1 -Backend openai -Model gpt-image-1-mini -Count 4 -Description "a flat vector coffee logo" -OutputPath "$HOME\Pictures\logos"
.EXAMPLE
  .\generate-image.ps1 -Backend gemini -Model imagen-4.0-generate-001 -Description "a mountain lake at dawn"
.EXAMPLE
  .\generate-image.ps1 -Login -Provider gemini
#>
param(
    [string]$Description,
    [string]$OutputPath,
    [ValidateSet("agy", "gemini", "openai", "pollinations", "local", "auto")]
    [string]$Backend,
    [string]$Model,
    [ValidateRange(1, 10)]
    [int]$Count = 1,
    [string]$BatchFile,
    [string]$Reference,
    [string]$FromFile,
    [switch]$Check,
    [switch]$Login,
    [switch]$Logout,
    [ValidateSet("openai", "gemini")]
    [string]$Provider = "openai",
    [switch]$NoVerify,
    [string]$PreviewFor,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

# --- Mode: make a small JPEG preview of an image (for showing it in a chat) ------------
if ($PreviewFor) {
    if (-not (Test-Path $PreviewFor -PathType Leaf)) { Write-Error "File not found: $PreviewFor"; exit 1 }
    Add-Type -AssemblyName System.Drawing
    $src = [System.Drawing.Image]::FromFile((Resolve-Path $PreviewFor).Path)
    try {
        $max = 1024
        $scale = [Math]::Min(1.0, $max / [Math]::Max($src.Width, $src.Height))
        $w = [Math]::Max(1, [int]($src.Width * $scale)); $h = [Math]::Max(1, [int]($src.Height * $scale))
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($src, 0, 0, $w, $h)
        $g.Dispose()
        $dir = Join-Path $env:TEMP "agy-imagegen\preview"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $out = Join-Path $dir ("preview-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".jpg")
        $enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
        $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]82)
        $bmp.Save($out, $enc, $ep)
        $bmp.Dispose()
    }
    finally { $src.Dispose() }
    Write-Output $out
    return
}

# --- Locating agy --------------------------------------------------------------------
function Find-Agy {
    if ($env:AGY_EXE) { if (Test-Path $env:AGY_EXE) { return $env:AGY_EXE } else { return $null } }
    $cmd = Get-Command agy -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $fallback = Join-Path $env:LOCALAPPDATA "agy\bin\agy.exe"
    if (Test-Path $fallback) { return $fallback }
    return $null
}

# --- API keys: environment first, else a saved sign-in (Windows DPAPI, this user only) ---
function Get-KeyFile([string]$P) { Join-Path $env:APPDATA "agy-imagegen\$P.key" }

function Get-EnvKey([string]$P) {
    if ($P -eq "openai") { return $env:OPENAI_API_KEY }
    if ($env:GEMINI_API_KEY) { return $env:GEMINI_API_KEY }
    return $env:GOOGLE_API_KEY
}

function Get-ApiKey([string]$P) {
    $e = Get-EnvKey $P
    if ($e) { return $e }
    $f = Get-KeyFile $P
    if (Test-Path $f) {
        try {
            $sec = (Get-Content $f -Raw).Trim() | ConvertTo-SecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        catch { return $null }
    }
    return $null
}

function Get-KeySource([string]$P) {
    if (Get-EnvKey $P) { return "environment variable" }
    if (Test-Path (Get-KeyFile $P)) { return "saved sign-in" }
    return $null
}

function Get-AvailableBackends {
    $list = @()
    if (Find-Agy) { $list += "agy" }
    if (Get-ApiKey "gemini") { $list += "gemini" }
    if (Get-ApiKey "openai") { $list += "openai" }
    if ($env:IMAGEGEN_LOCAL_URL) { $list += "local" }
    return $list
}

function Get-EnabledBackends {
    $avail = @(Get-AvailableBackends)
    if (-not $env:IMAGEGEN_BACKENDS) { return $avail }
    $want = $env:IMAGEGEN_BACKENDS.ToLower().Split(@(',', ' ', ';'), [StringSplitOptions]::RemoveEmptyEntries)
    $out = @($avail | Where-Object { $_ -in $want })
    if ($want -contains "pollinations") { $out += "pollinations" }
    return $out
}

function Say([string]$Text) { [Console]::Error.WriteLine($Text) }

if ($Logout) {
    $f = Get-KeyFile $Provider
    if (Test-Path $f) { Remove-Item $f -Force; "Signed out: saved $Provider key removed." }
    else { "No saved $Provider sign-in found." }
    if (Get-EnvKey $Provider) { "Note: the $Provider API key is still set in your environment." }
    return
}

if ($Login) {
    $keyUrl = if ($Provider -eq "openai") { "https://platform.openai.com/api-keys" } else { "https://aistudio.google.com/apikey" }
    Write-Host "Sign in to $Provider for image generation."
    Write-Host "Create or copy an API key at $keyUrl"
    if ([Console]::IsInputRedirected) {
        # Key piped in (e.g. from a secrets manager): read one line from stdin.
        $plain = ([Console]::In.ReadLine())
        if ($plain) { $plain = $plain.Trim() }
    }
    else {
        $sec = Read-Host "Paste your $Provider API key (input hidden)" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if (-not $plain -or $plain.Length -lt 20) { Write-Error "That doesn't look like an API key."; exit 1 }

    if (-not $NoVerify) {
        try {
            if ($Provider -eq "openai") {
                $base = if ($env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL.TrimEnd('/') } else { "https://api.openai.com/v1" }
                [void](Invoke-RestMethod -Uri "$base/models" -Headers @{ Authorization = "Bearer $plain" } -TimeoutSec 30)
            }
            else {
                [void](Invoke-RestMethod -Uri "https://generativelanguage.googleapis.com/v1beta/models" -Headers @{ "x-goog-api-key" = $plain } -TimeoutSec 30)
            }
        }
        catch {
            $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($code -in 400, 401, 403) { Write-Error "$Provider rejected that key ($code). Nothing was saved."; exit 1 }
            Write-Error "Could not verify the key ($($_.Exception.Message)). Nothing was saved. Re-run with -NoVerify to save it anyway."
            exit 1
        }
    }
    $f = Get-KeyFile $Provider
    $dir = Split-Path $f -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($plain | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString) | Set-Content $f -Encoding ASCII
    $plain = $null
    "Signed in to $Provider. Key saved encrypted for this Windows account at $f."
    "Use it with: -Backend $Provider   (sign out any time with -Logout -Provider $Provider)"
    return
}

if ($Check) {
    $a = Find-Agy
    function KeyLine([string]$P, [string]$Model) {
        if (Get-ApiKey $P) { "available (" + (Get-KeySource $P) + ", model $Model)" } else { "not signed in (run -Login -Provider $P, or set the API key env var)" }
    }
    "agy:          " + $(if ($a) { "available ($a)" } else { "not found" })
    "gemini:       " + (KeyLine "gemini" $(if ($env:GEMINI_IMAGE_MODEL) { $env:GEMINI_IMAGE_MODEL } else { "gemini-2.5-flash-image" }))
    "openai:       " + (KeyLine "openai" $(if ($env:OPENAI_IMAGE_MODEL) { $env:OPENAI_IMAGE_MODEL } else { "gpt-image-2" }))
    "pollinations: free, no key (model " + $(if ($env:POLLINATIONS_MODEL) { $env:POLLINATIONS_MODEL } else { "flux" }) + "); used by auto only if listed in IMAGEGEN_BACKENDS"
    "local:        " + $(if ($env:IMAGEGEN_LOCAL_URL) { "available ($($env:IMAGEGEN_LOCAL_URL))" } else { "not configured (set IMAGEGEN_LOCAL_URL)" })
    $def = if ($env:IMAGEGEN_BACKEND) { $env:IMAGEGEN_BACKEND } else { "agy" }
    "default backend: $def"
    "enabled for auto: " + ((Get-EnabledBackends) -join ", ")
    return
}

# --- Work out what to generate -------------------------------------------------------
$jobs = @()
if ($BatchFile) {
    if (-not (Test-Path $BatchFile -PathType Leaf)) { Write-Error "Batch file not found: $BatchFile"; exit 1 }
    $jobs = @(Get-Content $BatchFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($jobs.Count -eq 0) { Write-Error "Batch file has no descriptions."; exit 1 }
    if ($jobs.Count -gt 20) { Write-Error "Batch file has $($jobs.Count) lines; the maximum is 20."; exit 1 }
}
elseif ($Description) {
    $jobs = @(1..$Count | ForEach-Object { $Description })
}
elseif (-not $FromFile) {
    Write-Error "Provide -Description (or -BatchFile, -FromFile, or -Check)."
    exit 1
}

$refs = @()
if ($Reference) {
    foreach ($r in $Reference.Split('|', [StringSplitOptions]::RemoveEmptyEntries)) {
        $r = $r.Trim()
        if (-not (Test-Path $r -PathType Leaf)) { Write-Error "Reference image not found: $r"; exit 1 }
        $refs += (Resolve-Path $r).Path
    }
}

if (-not $Backend) { $Backend = if ($env:IMAGEGEN_BACKEND) { $env:IMAGEGEN_BACKEND.ToLower() } else { "agy" } }
if ($Backend -notin "agy", "gemini", "openai", "pollinations", "local", "auto") {
    Write-Error "Unknown backend '$Backend'. Use agy, gemini, openai, pollinations, local or auto."
    exit 1
}

# --- Resolve where each image will go ------------------------------------------------
$DefaultDir = if ($env:AGY_IMAGE_DIR) { $env:AGY_IMAGE_DIR } else { Join-Path ([Environment]::GetFolderPath("MyPictures")) "Generated" }

function Resolve-Out([string]$Label, [int]$Index, [int]$Total) {
    $out = $OutputPath
    $multi = $Total -gt 1
    # An existing folder, or a path with no file extension, is treated as a folder.
    if (-not $out -or (Test-Path $out -PathType Container) -or -not [IO.Path]::GetExtension($out)) {
        $dir = if ($out) { $out } else { $DefaultDir }
        $slug = ($Label.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
        if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
        if (-not $slug) { $slug = "image" }
        $name = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $slug
        if ($multi) { $name += ("-{0:00}" -f $Index) }
        $out = Join-Path $dir ($name + ".png")
    }
    elseif ($multi) {
        $out = Join-Path (Split-Path $out -Parent) ("{0}-{1:00}{2}" -f [IO.Path]::GetFileNameWithoutExtension($out), $Index, [IO.Path]::GetExtension($out))
    }
    $out = [System.IO.Path]::GetFullPath($out)
    $d = Split-Path $out -Parent
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    return $out
}

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
        throw "Cannot convert to .$dstExt (webp is not a supported output). Source image kept at $Source"
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
                Where-Object { $_.Extension -match '^\.(png|jpe?g|webp)$' -and $_.LastWriteTime -ge $Since -and $_.Name -notlike 'ref-*' } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($found) { Start-Sleep -Milliseconds 500; return $found }
        }
        Start-Sleep -Seconds 2
    }
    return $null
}

function Get-MimeType([string]$Path) {
    switch ([IO.Path]::GetExtension($Path).ToLower()) { '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.webp' { 'image/webp' } default { 'image/png' } }
}

# Writes image bytes to a temp file (extension sniffed from the magic bytes) and returns it.
function Save-Bytes([byte[]]$Bytes) {
    $ext = "png"
    if ($Bytes.Length -gt 3) {
        if ($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8) { $ext = "jpg" }
        elseif ($Bytes[0] -eq 0x52 -and $Bytes[1] -eq 0x49) { $ext = "webp" }
        elseif (-not ($Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50)) { throw "The service returned data that is not an image." }
    }
    $tmp = Join-Path $workDir ("api-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + "." + $ext)
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    return (Get-Item $tmp)
}

$workDir = Join-Path $env:TEMP "agy-imagegen"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# --- Mode: save an existing image ----------------------------------------------------
if ($FromFile) {
    if (-not (Test-Path $FromFile -PathType Leaf)) { Write-Error "File not found: $FromFile"; exit 1 }
    $label = if ($Description) { $Description } else { [System.IO.Path]::GetFileNameWithoutExtension($FromFile) }
    $dest = Resolve-Out $label 1 1
    Save-Image (Resolve-Path $FromFile).Path $dest
    Write-Output $dest
    return
}

# --- Backend: agy (Gemini via the Antigravity CLI) -----------------------------------
function Invoke-Agy([string]$Desc) {
    $exe = Find-Agy
    if (-not $exe) { throw "agy not found. Install the Antigravity CLI or set AGY_EXE." }
    $brain = if ($env:AGY_BRAIN_DIR) { $env:AGY_BRAIN_DIR } else { Join-Path $env:USERPROFILE ".gemini\antigravity-cli\brain" }

    $stdout = Join-Path $workDir "agy-stdout.json"
    $stderr = Join-Path $workDir "agy-stderr.txt"
    Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

    if ($refs.Count -gt 0) {
        # agy runs in $workDir, so copy the references there and name them in the prompt.
        $names = @()
        $i = 0
        foreach ($r in $refs) {
            $i++
            $n = "ref-{0}-{1}{2}" -f ([guid]::NewGuid().ToString("N").Substring(0, 6)), $i, [IO.Path]::GetExtension($r)
            Copy-Item $r (Join-Path $workDir $n) -Force
            $names += $n
        }
        $prompt = "Open and look at these reference image file(s) in the current folder: " + ($names -join ", ") +
            ". Then call your built-in image generation tool right now to generate an image of $Desc, using the reference image(s) as inspiration or as the thing to edit. " +
            "Do not run any commands and do not read any other files or skills."
    }
    else {
        $prompt = "Call your built-in image generation tool right now to generate an image of $Desc. " +
            "Do not read any files or skills and do not run any commands. Just generate the image."
    }

    # --disable-slash-commands: don't let this agy session load the image-generation skill
    # itself (that would recurse into the skill and then stall on a denied shell command).
    $started = Get-Date
    $proc = Start-Process -FilePath $exe `
        -ArgumentList @("--disable-slash-commands", "-p", (Quote-Arg $prompt), "--output-format", "json") `
        -WorkingDirectory $workDir -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        throw "agy timed out after $TimeoutSeconds seconds."
    }

    $raw = if (Test-Path $stdout) { Get-Content $stdout -Raw } else { "" }
    try { $result = $raw | ConvertFrom-Json } catch { $result = $null }
    if (-not $result -or -not $result.conversation_id) {
        $err = if (Test-Path $stderr) { Get-Content $stderr -Raw } else { "" }
        throw "agy returned no usable JSON (exit $($proc.ExitCode)). stdout: $raw stderr: $err"
    }

    # If agy already reports that generation failed (quota, etc.), don't wait for an image that will never come.
    if ($result.response -match '(?i)RESOURCE_EXHAUSTED|quota|capacity|rate.?limit|\b429\b|generation failed|could not (create|generate)|no image could be') {
        $found = Get-ChildItem (Join-Path $brain $result.conversation_id) -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(png|jpe?g|webp)$' -and $_.LastWriteTime -ge $started.AddSeconds(-5) } | Select-Object -First 1
        if (-not $found) { throw "agy could not generate the image: $($result.response)" }
    }

    # agy replies before its image subagent always finishes, so poll the conversation folder.
    $image = Wait-ForImage @((Join-Path $brain $result.conversation_id)) $started.AddSeconds(-5)
    if (-not $image) { throw "No image appeared for agy conversation $($result.conversation_id). agy said: $($result.response)" }
    return $image
}

# --- Backends: openai (API key) and local (OpenAI-compatible server) ------------------
function Invoke-ImagesApi([string]$Desc, [string]$Base, [string]$Key, [string]$ModelName, [string]$Tag) {
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    if ($Key) { $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $Key) }
    $Base = $Base.TrimEnd('/')
    try {
        if ($refs.Count -gt 0) {
            $form = New-Object System.Net.Http.MultipartFormDataContent
            if ($ModelName) { $form.Add((New-Object System.Net.Http.StringContent($ModelName)), "model") }
            $form.Add((New-Object System.Net.Http.StringContent($Desc, [Text.Encoding]::UTF8)), "prompt")
            foreach ($r in $refs) {
                $part = New-Object System.Net.Http.ByteArrayContent(, [IO.File]::ReadAllBytes($r))
                $part.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse((Get-MimeType $r))
                $form.Add($part, "image[]", [IO.Path]::GetFileName($r))
            }
            $resp = $client.PostAsync("$Base/images/edits", $form).GetAwaiter().GetResult()
        }
        else {
            $payload = @{ prompt = $Desc; n = 1 }
            if ($ModelName) { $payload.model = $ModelName }
            $json = $payload | ConvertTo-Json -Compress
            $content = New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, "application/json")
            $resp = $client.PostAsync("$Base/images/generations", $content).GetAwaiter().GetResult()
        }
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) { throw "$Tag images API returned $([int]$resp.StatusCode): $body" }

        $obj = $body | ConvertFrom-Json
        $item = @($obj.data)[0]
        if (-not $item) { throw "$Tag images API returned no image: $body" }
        if ($item.b64_json) { $bytes = [Convert]::FromBase64String($item.b64_json) }
        elseif ($item.url) { $bytes = $client.GetByteArrayAsync($item.url).GetAwaiter().GetResult() }
        else { throw "$Tag images API returned neither b64_json nor url: $body" }
    }
    finally { $client.Dispose() }
    return (Save-Bytes $bytes)
}

function Invoke-OpenAI([string]$Desc) {
    $key = Get-ApiKey "openai"
    if (-not $key) { throw "Not signed in to OpenAI. Run the script with -Login once (or set OPENAI_API_KEY)." }
    $base = if ($env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL } else { "https://api.openai.com/v1" }
    $m = if ($Model) { $Model } elseif ($env:OPENAI_IMAGE_MODEL) { $env:OPENAI_IMAGE_MODEL } else { "gpt-image-2" }
    return Invoke-ImagesApi $Desc $base $key $m "OpenAI"
}

function Invoke-Local([string]$Desc) {
    if (-not $env:IMAGEGEN_LOCAL_URL) { throw "IMAGEGEN_LOCAL_URL is not set. Point it at a local OpenAI-compatible image server, e.g. http://127.0.0.1:8080/v1" }
    $m = if ($Model) { $Model } else { $env:IMAGEGEN_LOCAL_MODEL }
    return Invoke-ImagesApi $Desc $env:IMAGEGEN_LOCAL_URL $null $m "Local"
}

# --- Backend: gemini (Gemini API: Gemini image models and Imagen) --------------------
function Invoke-GeminiApi([string]$Desc) {
    $key = Get-ApiKey "gemini"
    if (-not $key) { throw "Not signed in to Gemini. Run the script with -Login -Provider gemini once (or set GEMINI_API_KEY)." }
    $m = if ($Model) { $Model } elseif ($env:GEMINI_IMAGE_MODEL) { $env:GEMINI_IMAGE_MODEL } else { "gemini-2.5-flash-image" }
    $base = "https://generativelanguage.googleapis.com/v1beta/models/$m"
    $headers = @{ "x-goog-api-key" = $key }

    try {
        if ($m -like "imagen*") {
            if ($refs.Count -gt 0) { throw "Imagen models don't take reference images. Use a Gemini image model (e.g. gemini-2.5-flash-image) or drop -Reference." }
            $body = @{ instances = @(@{ prompt = $Desc }); parameters = @{ sampleCount = 1 } } | ConvertTo-Json -Depth 6 -Compress
            $resp = Invoke-RestMethod -Method Post -Uri "${base}:predict" -Headers $headers -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec $TimeoutSeconds
            $b64 = @($resp.predictions)[0].bytesBase64Encoded
            if (-not $b64) { throw "Imagen returned no image (it may have been filtered). Response: $($resp | ConvertTo-Json -Depth 4 -Compress)" }
        }
        else {
            $parts = @(@{ text = $Desc })
            foreach ($r in $refs) { $parts += @{ inline_data = @{ mime_type = (Get-MimeType $r); data = [Convert]::ToBase64String([IO.File]::ReadAllBytes($r)) } } }
            $body = @{ contents = @(@{ parts = $parts }); generationConfig = @{ responseModalities = @("TEXT", "IMAGE") } } | ConvertTo-Json -Depth 8 -Compress
            $resp = Invoke-RestMethod -Method Post -Uri "${base}:generateContent" -Headers $headers -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec $TimeoutSeconds
            $b64 = $null
            foreach ($p in @($resp.candidates)[0].content.parts) {
                if ($p.inlineData -and $p.inlineData.data) { $b64 = $p.inlineData.data; break }
                if ($p.inline_data -and $p.inline_data.data) { $b64 = $p.inline_data.data; break }
            }
            if (-not $b64) {
                $said = (@($resp.candidates)[0].content.parts | Where-Object { $_.text } | ForEach-Object { $_.text }) -join " "
                throw "Gemini returned no image. It said: $said"
            }
        }
    }
    catch {
        $detail = ""
        try { $detail = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
        throw ("Gemini API error: " + $_.Exception.Message + $(if ($detail) { " $detail" }))
    }
    return (Save-Bytes ([Convert]::FromBase64String($b64)))
}

# --- Backend: pollinations (free public service, no key) -----------------------------
function Invoke-Pollinations([string]$Desc) {
    if ($refs.Count -gt 0) { throw "The pollinations backend doesn't take reference images. Use agy, gemini, openai or local." }
    $m = if ($Model) { $Model } elseif ($env:POLLINATIONS_MODEL) { $env:POLLINATIONS_MODEL } else { "flux" }
    $url = "https://image.pollinations.ai/prompt/" + [Uri]::EscapeDataString($Desc) + "?model=" + [Uri]::EscapeDataString($m) + "&width=1024&height=1024&nologo=true&seed=" + (Get-Random -Maximum 999999)
    $tmp = Join-Path $workDir ("poll-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".bin")
    try { Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec $TimeoutSeconds | Out-Null }
    catch {
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        $hint = if ($code -in 402, 429) { " The free anonymous tier has a usage limit and is rate-limited right now; wait a while or use another backend (agy, gemini, openai, local)." } else { "" }
        throw "Pollinations request failed: $($_.Exception.Message).$hint"
    }
    return (Save-Bytes ([IO.File]::ReadAllBytes($tmp)))
}

# --- Backend choice for -Backend auto ------------------------------------------------
function Select-Backend([string]$Desc) {
    $enabled = @(Get-EnabledBackends)
    if ($enabled.Count -eq 0) { throw "No image backend is available/enabled. Run with -Check to see what is detected." }
    if ($enabled.Count -eq 1) { return $enabled[0] }

    # Text-heavy or precise-layout requests, and edits of reference images, go to OpenAI first;
    # everything else goes to Gemini (agy) first. Local/free models are the choice for quick drafts.
    $precise = ($refs.Count -gt 0) -or ($Desc -match '(?i)\b(text|logo|typograph|lettering|poster|sign|label|diagram|infographic|ui|screenshot|mockup|icon|slide|menu)\b')
    $draft = $Desc -match '(?i)\b(draft|sketch|rough|quick|placeholder)\b'
    $order = if ($draft) { @("local", "pollinations", "agy", "gemini", "openai") }
             elseif ($precise) { @("openai", "gemini", "agy", "local", "pollinations") }
             else { @("agy", "gemini", "openai", "local", "pollinations") }
    # Pollinations can't take references.
    if ($refs.Count -gt 0) { $order = @($order | Where-Object { $_ -ne "pollinations" }) }
    foreach ($b in $order) { if ($enabled -contains $b) { return $b } }
    return $enabled[0]
}

function New-OneImage([string]$Desc, [string]$Chosen) {
    switch ($Chosen) {
        "openai"       { return Invoke-OpenAI $Desc }
        "gemini"       { return Invoke-GeminiApi $Desc }
        "pollinations" { return Invoke-Pollinations $Desc }
        "local"        { return Invoke-Local $Desc }
        default        { return Invoke-Agy $Desc }
    }
}

# --- Run ----------------------------------------------------------------------------
$total = $jobs.Count
$failed = 0
for ($i = 0; $i -lt $total; $i++) {
    $desc = $jobs[$i]
    try {
        $chosen = if ($Backend -eq "auto") { Select-Backend $desc } else { $Backend }
        Say ("[{0}/{1}] backend: {2}" -f ($i + 1), $total, $chosen)
        $image = New-OneImage $desc $chosen
        $dest = Resolve-Out $desc ($i + 1) $total
        Save-Image $image.FullName $dest
        Write-Output $dest
    }
    catch {
        $failed++
        Say ("[{0}/{1}] FAILED: {2}" -f ($i + 1), $total, $_.Exception.Message)
    }
}
if ($failed -gt 0) { exit 1 }
