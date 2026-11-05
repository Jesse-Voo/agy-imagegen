---
name: image-generation
description: Generate an image from a text description using Gemini through the Antigravity CLI (agy) and save it to disk. Use when the user asks to create, generate, draw, or make an image, picture, illustration, logo, icon, or artwork.
---

# Image generation (Gemini via Antigravity CLI)

Generates images by driving the Antigravity CLI (`agy`) headlessly and copying the result to a path of your choice. Windows + PowerShell.

## How to run

Run the bundled script with PowerShell. The script lives in `scripts/generate-image.ps1`, next to this file.

```powershell
powershell.exe -NoProfile -File "<skill dir>\scripts\generate-image.ps1" -Description "<what to draw>" [-OutputPath "<where to save>"]
```

- `-Description` (required): what the image should show. Write it as a vivid, specific description including style, e.g. `a red fox in a snowy forest, watercolor style`. Do not include the words "make an image of"; the script adds that.
- `-OutputPath` (optional): full destination path including filename, e.g. `C:\Users\me\Pictures\fox.png`. Missing folders are created. The extension decides the format (`.png`, `.jpg`/`.jpeg`, `.bmp`, `.gif`).
  - If the user told you where to save, pass it.
  - **If the user did not say where to save, omit `-OutputPath`.** The image goes to the default folder (`<Pictures>\Generated`, or `$env:AGY_IMAGE_DIR` if set) with an auto-generated name like `20261105-142233-a-red-fox-in-a-snowy-forest.png`. Never guess a random location.
- The script prints the final saved path as the last line of output. Report that path to the user, and view the image if you can.
- Generation takes roughly 30-90 seconds. Allow a timeout of at least 300 seconds when calling the script.

If PowerShell blocks the script because of the execution policy, tell the user and let them decide whether to relax the policy; do not silently bypass it.

If the `generate_image` MCP tool from this repo's `mcp/` server is available, it does the same thing and can be used instead.

## Rules

- Do not use `--dangerously-skip-permissions` with `agy`. The script deliberately does not need it.
- Generate one image per call. For variations, call again with a changed description.
- If it fails, read the error: the usual causes are `agy` not installed or not signed in (run `agy` once interactively to log in), or a timeout. Report the real error rather than retrying blindly.

## Requirements

- Windows with PowerShell 5.1+ (or PowerShell 7)
- [Antigravity CLI](https://antigravity.google) (`agy`) installed and signed in
