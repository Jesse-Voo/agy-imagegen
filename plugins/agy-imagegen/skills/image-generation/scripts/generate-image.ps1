<#
.SYNOPSIS
  Generates images with Gemini (Antigravity CLI "agy"), OpenAI (Codex CLI or the OpenAI API) or a
  local OpenAI-compatible image server, and saves them to disk.

.DESCRIPTION
  Modes:

    Generate  (default)   Runs the chosen backend headlessly, waits for the image, saves it.
    -FromFile <path>      Skips generation: takes an image another tool already made (for
                          example agy's or Codex's built-in image tool) and saves it to
                          OutputPath / the default folder, converting format if needed.
    -Check                Prints which backends are available and exits.

  Backends (-Backend, or env IMAGEGEN_BACKEND; default agy):
    agy     agy -p ... --output-format json (Gemini). agy's image tool writes under
            <brain>\<conversation_id>\; the id is read from the JSON output.
    codex   codex exec ... in a scratch folder, asking Codex's built-in $imagegen
            (gpt-image-2) to save the file there. Uses your Codex sign-in.
    openai  Calls the OpenAI Images API directly with OPENAI_API_KEY (no Codex needed).
    local   Calls a local OpenAI-compatible image server at IMAGEGEN_LOCAL_URL
            (e.g. http://127.0.0.1:8080/v1). No key needed.
    auto    Picks one of the enabled, available backends based on the request.
            "Enabled" = IMAGEGEN_BACKENDS (comma list); default is every available backend.

  Bulk:       -Count N makes N variations of -Description; -BatchFile <txt> makes one image per
              non-empty line. Several images get -01, -02 ... suffixes. Results print one path per line.
  References: -Reference "a.png|b.jpg" passes existing images to the model as inspiration/input.

  No backend is run with a permission bypass: the script itself does the copying.
  The saved path(s) are printed as the last line(s) of stdout; the backend used goes to stderr.

.PARAMETER Description
  What the image should depict.

.PARAMETER OutputPath
  Optional. File path (.png, .jpg/.jpeg, .bmp, .gif) or an existing folder. If omitted, files are
  named <timestamp>-<description-slug>.png in the default folder.

.PARAMETER Backend
  agy | codex | openai | local | auto.

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

.PARAMETER TimeoutSeconds
  Give up on each image after this many seconds. Default 300.

.NOTES
  ENVIRONMENT (all optional):
    IMAGEGEN_BACKEND      Default backend: agy, codex, openai, local or auto.
    IMAGEGEN_BACKENDS     Backends the AI may choose from with auto, e.g. "agy,openai".
    AGY_EXE               Full path to agy.exe. Default: agy on PATH, else %LOCALAPPDATA%\agy\bin\agy.exe
    AGY_BRAIN_DIR         agy's conversation folder. Default: ~\.gemini\antigravity-cli\brain
    CODEX_EXE             Full path to the codex executable. Default: codex on PATH
    CODEX_HOME            Codex's home folder. Default: ~\.codex
    OPENAI_API_KEY        Enables the openai backend.
    OPENAI_BASE_URL       Default https://api.openai.com/v1
    OPENAI_IMAGE_MODEL    Default gpt-image-2
    IMAGEGEN_LOCAL_URL    Base URL of a local OpenAI-compatible image server; enables the local backend.
    IMAGEGEN_LOCAL_MODEL  Model name to send to the local server (optional).
    AGY_IMAGE_DIR         Default save folder. Default: <Pictures>\Generated

.EXAMPLE
  .\generate-image.ps1 -Check
.EXAMPLE
  .\generate-image.ps1 -Description "a red fox in a snowy forest, watercolor style"
.EXAMPLE
  .\generate-image.ps1 -Backend openai -Count 4 -Description "a flat vector coffee logo" -OutputPath "$HOME\Pictures\logos"
.EXAMPLE
  .\generate-image.ps1 -Backend auto -Reference "$HOME\Pictures\sketch.png" -Description "turn this sketch into a polished poster"
.EXAMPLE
  .\generate-image.ps1 -FromFile "C:\path\to\generated.jpg" -Description "a red fox" -OutputPath "$HOME\Pictures\fox.png"
#>
param(
    [string]$Description,
    [string]$OutputPath,
    [ValidateSet("agy", "codex", "openai", "local", "auto")]
    [string]$Backend,
    [ValidateRange(1, 10)]
    [int]$Count = 1,
    [string]$BatchFile,
    [string]$Reference,
    [string]$FromFile,
    [switch]$Check,
    [switch]$Login,
    [switch]$Logout,
    [switch]$NoVerify,
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
    # The Codex desktop app ships its own CLI that is not on PATH.
    $app = Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin\codex.exe"
    if (Test-Path $app) { return $app }
    return $null
}

# --- OpenAI sign-in: an API key kept encrypted (Windows DPAPI, this user only) ---------
$KeyFile = Join-Path $env:APPDATA "agy-imagegen\openai.key"

function Get-OpenAIKey {
    if ($env:OPENAI_API_KEY) { return $env:OPENAI_API_KEY }
    if (Test-Path $KeyFile) {
        try {
            $sec = (Get-Content $KeyFile -Raw).Trim() | ConvertTo-SecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        }
        catch { return $null }
    }
    return $null
}

function Get-OpenAIKeySource {
    if ($env:OPENAI_API_KEY) { return "OPENAI_API_KEY environment variable" }
    if (Test-Path $KeyFile) { return "saved sign-in ($KeyFile)" }
    return $null
}

function Get-AvailableBackends {
    $list = @()
    if (Find-Agy) { $list += "agy" }
    if (Find-Codex) { $list += "codex" }
    if (Get-OpenAIKey) { $list += "openai" }
    if ($env:IMAGEGEN_LOCAL_URL) { $list += "local" }
    return $list
}

function Get-EnabledBackends {
    $avail = @(Get-AvailableBackends)
    if (-not $env:IMAGEGEN_BACKENDS) { return $avail }
    $want = $env:IMAGEGEN_BACKENDS.ToLower().Split(@(',', ' ', ';'), [StringSplitOptions]::RemoveEmptyEntries)
    return @($avail | Where-Object { $_ -in $want })
}

function Say([string]$Text) { [Console]::Error.WriteLine($Text) }

if ($Logout) {
    if (Test-Path $KeyFile) { Remove-Item $KeyFile -Force; "Signed out: saved OpenAI key removed." }
    else { "No saved OpenAI sign-in found." }
    if ($env:OPENAI_API_KEY) { "Note: OPENAI_API_KEY is still set in your environment." }
    return
}

if ($Login) {
    Write-Host "Sign in to OpenAI for image generation."
    Write-Host "Create or copy an API key at https://platform.openai.com/api-keys (it is shown only once)."
    if ([Console]::IsInputRedirected) {
        # Key piped in (e.g. from a secrets manager): read one line from stdin.
        $plain = ([Console]::In.ReadLine())
        if ($plain) { $plain = $plain.Trim() }
    }
    else {
        $sec = Read-Host "Paste your OpenAI API key (input hidden)" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if (-not $plain -or $plain.Length -lt 20) { Write-Error "That doesn't look like an API key."; exit 1 }

    if (-not $NoVerify) {
        $base = if ($env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL.TrimEnd('/') } else { "https://api.openai.com/v1" }
        try {
            [void](Invoke-RestMethod -Uri "$base/models" -Headers @{ Authorization = "Bearer $plain" } -TimeoutSec 30)
        }
        catch {
            $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($code -eq 401) { Write-Error "OpenAI rejected that key (401). Nothing was saved."; exit 1 }
            Write-Error "Could not verify the key ($($_.Exception.Message)). Nothing was saved. Re-run with -NoVerify to save it anyway."
            exit 1
        }
    }
    $dir = Split-Path $KeyFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    ($plain | ConvertTo-SecureString -AsPlainText -Force | ConvertFrom-SecureString) | Set-Content $KeyFile -Encoding ASCII
    $plain = $null
    "Signed in. Key saved encrypted for this Windows account at $KeyFile."
    "Use it with: -Backend openai   (sign out any time with -Logout)"
    return
}

if ($Check) {
    $a = Find-Agy
    $c = Find-Codex
    "agy:    " + $(if ($a) { "available ($a)" } else { "not found" })
    "codex:  " + $(if ($c) { "available ($c)" } else { "not found" })
    "openai: " + $(if (Get-OpenAIKey) { "available (" + (Get-OpenAIKeySource) + ", model " + $(if ($env:OPENAI_IMAGE_MODEL) { $env:OPENAI_IMAGE_MODEL } else { "gpt-image-2" }) + ")" } else { "not signed in (run -Login, or set OPENAI_API_KEY)" })
    "local:  " + $(if ($env:IMAGEGEN_LOCAL_URL) { "available ($($env:IMAGEGEN_LOCAL_URL))" } else { "not configured (set IMAGEGEN_LOCAL_URL)" })
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
if ($Backend -notin "agy", "codex", "openai", "local", "auto") {
    Write-Error "Unknown backend '$Backend'. Use agy, codex, openai, local or auto."
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

# --- Backend: agy (Gemini) -----------------------------------------------------------
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

    # agy replies before its image subagent always finishes, so poll the conversation folder.
    $image = Wait-ForImage @((Join-Path $brain $result.conversation_id)) $started.AddSeconds(-5)
    if (-not $image) { throw "No image appeared for agy conversation $($result.conversation_id). agy said: $($result.response)" }
    return $image
}

# --- Backend: codex (OpenAI gpt-image-2 via the built-in $imagegen skill) -------------
function Invoke-Codex([string]$Desc) {
    $exe = Find-Codex
    if (-not $exe) { throw "codex not found. Install the Codex CLI (npm i -g @openai/codex), sign in, or set CODEX_EXE." }
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }

    # A scratch workspace Codex is allowed to write into (workspace-write sandbox).
    $scratch = Join-Path $workDir ("codex-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null

    $prompt = 'Use the $imagegen skill to generate an image of ' + $Desc +
        $(if ($refs.Count -gt 0) { ', using the attached image(s) as reference' } else { '' }) +
        '. Use only $imagegen for this; do not use any other skill or run any other helper. Save the final image as image.png in the current working directory, then reply with only the file name.'

    $stdout = Join-Path $scratch "codex-stdout.txt"
    $stderr = Join-Path $scratch "codex-stderr.txt"

    $argList = @("exec", "--skip-git-repo-check", "--sandbox", "workspace-write")
    # codex exec --image/-i attaches images to the prompt (comma-separated list).
    if ($refs.Count -gt 0) { $argList += @("--image", (Quote-Arg ($refs -join ","))) }
    $argList += (Quote-Arg $prompt)

    $started = Get-Date
    $proc = Start-Process -FilePath $exe -ArgumentList $argList `
        -WorkingDirectory $scratch -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr

    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        throw "codex timed out after $TimeoutSeconds seconds."
    }

    # Preferred: the file Codex was told to save here. Fallback: Codex's own generated_images store.
    # codex exec has already exited, so the file is either there now or never will be:
    # use a short grace period instead of polling for the full timeout.
    $saved = $TimeoutSeconds
    $script:TimeoutSeconds = 6
    try {
        $image = Wait-ForImage @($scratch) $started.AddSeconds(-5)
        if (-not $image) { $image = Wait-ForImage @((Join-Path $codexHome "generated_images")) $started.AddSeconds(-5) -Recurse }
    }
    finally { $script:TimeoutSeconds = $saved }
    if (-not $image) {
        $err = if (Test-Path $stderr) { (Get-Content $stderr -Raw) } else { "" }
        $out = if (Test-Path $stdout) { (Get-Content $stdout -Raw) } else { "" }
        throw "No image produced by codex (exit $($proc.ExitCode)). stdout: $out stderr: $err"
    }
    return $image
}

# --- Backends: openai (API key) and local (OpenAI-compatible server) ------------------
function Invoke-ImagesApi([string]$Desc, [string]$Base, [string]$Key, [string]$Model, [string]$Tag) {
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    if ($Key) { $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $Key) }
    $Base = $Base.TrimEnd('/')
    try {
        if ($refs.Count -gt 0) {
            $form = New-Object System.Net.Http.MultipartFormDataContent
            if ($Model) { $form.Add((New-Object System.Net.Http.StringContent($Model)), "model") }
            $form.Add((New-Object System.Net.Http.StringContent($Desc, [Text.Encoding]::UTF8)), "prompt")
            foreach ($r in $refs) {
                $part = New-Object System.Net.Http.ByteArrayContent(, [IO.File]::ReadAllBytes($r))
                $mime = switch ([IO.Path]::GetExtension($r).ToLower()) { '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.webp' { 'image/webp' } default { 'image/png' } }
                $part.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($mime)
                $form.Add($part, "image[]", [IO.Path]::GetFileName($r))
            }
            $resp = $client.PostAsync("$Base/images/edits", $form).GetAwaiter().GetResult()
        }
        else {
            $payload = @{ prompt = $Desc; n = 1 }
            if ($Model) { $payload.model = $Model }
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

    $ext = if ($bytes.Length -gt 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) { "jpg" } else { "png" }
    $tmp = Join-Path $workDir ("api-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + "." + $ext)
    [IO.File]::WriteAllBytes($tmp, $bytes)
    return (Get-Item $tmp)
}

function Invoke-OpenAI([string]$Desc) {
    $key = Get-OpenAIKey
    if (-not $key) { throw "Not signed in to OpenAI. Run the script with -Login once (or set OPENAI_API_KEY)." }
    $base = if ($env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL } else { "https://api.openai.com/v1" }
    $model = if ($env:OPENAI_IMAGE_MODEL) { $env:OPENAI_IMAGE_MODEL } else { "gpt-image-2" }
    return Invoke-ImagesApi $Desc $base $key $model "OpenAI"
}

function Invoke-Local([string]$Desc) {
    if (-not $env:IMAGEGEN_LOCAL_URL) { throw "IMAGEGEN_LOCAL_URL is not set. Point it at a local OpenAI-compatible image server, e.g. http://127.0.0.1:8080/v1" }
    return Invoke-ImagesApi $Desc $env:IMAGEGEN_LOCAL_URL $null $env:IMAGEGEN_LOCAL_MODEL "Local"
}

# --- Backend choice for -Backend auto ------------------------------------------------
function Select-Backend([string]$Desc) {
    $enabled = @(Get-EnabledBackends)
    if ($enabled.Count -eq 0) { throw "No image backend is available/enabled. Run with -Check to see what is detected." }
    if ($enabled.Count -eq 1) { return $enabled[0] }

    # Text-heavy or precise-layout requests, and edits of reference images, go to OpenAI first;
    # everything else goes to Gemini first. A local model is the last resort unless the request is a quick draft.
    $precise = ($refs.Count -gt 0) -or ($Desc -match '(?i)\b(text|logo|typograph|lettering|poster|sign|label|diagram|infographic|ui|screenshot|mockup|icon|slide|menu)\b')
    $draft = $Desc -match '(?i)\b(draft|sketch|rough|quick|placeholder)\b'
    $order = if ($draft -and $enabled -contains "local") { @("local", "agy", "openai", "codex") }
             elseif ($precise) { @("openai", "codex", "agy", "local") }
             else { @("agy", "openai", "codex", "local") }
    foreach ($b in $order) { if ($enabled -contains $b) { return $b } }
    return $enabled[0]
}

function New-OneImage([string]$Desc, [string]$Chosen) {
    switch ($Chosen) {
        "codex"  { return Invoke-Codex $Desc }
        "openai" { return Invoke-OpenAI $Desc }
        "local"  { return Invoke-Local $Desc }
        default  { return Invoke-Agy $Desc }
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
