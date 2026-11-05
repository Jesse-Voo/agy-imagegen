---
name: image-generation
description: Generate an image from a text description and save it to disk. Uses Gemini (Antigravity CLI) or OpenAI gpt-image-2 (Codex), whichever fits the agent you are running in. Use when the user asks to create, generate, draw, or make an image, picture, illustration, logo, icon, or artwork.
---

# Image generation (Gemini or OpenAI)

Turns a text description into an image file. Windows + PowerShell. Two image backends:

| Backend | Model | Needs |
| --- | --- | --- |
| `agy` | Gemini (via the Antigravity CLI) | `agy` installed and signed in |
| `codex` | OpenAI `gpt-image-2` (via the Codex CLI) | `codex` installed and signed in. Note: headless `codex exec` exposes no image tool on some setups (seen with ChatGPT sign-in); if it fails with "no image generation tool", use `openai` instead |
| `openai` | OpenAI Images API, no Codex needed | signed in (`-Login` once, run by the user in a terminal; never ask them to paste a key into chat) or `OPENAI_API_KEY` set |
| `local` | A local OpenAI-compatible image server | `IMAGEGEN_LOCAL_URL` set |
| `auto` | Picks one of the above for you | `IMAGEGEN_BACKENDS` limits the choice (e.g. `agy,openai`) |

The helper script is `scripts/generate-image.ps1`, next to this file. Below, `<skill dir>` means this skill's folder.

## Skip this skill when you were launched by it

The helper script starts `agy` and `codex` headlessly with a prompt like "Call your built-in image generation tool right now ...". If that is your whole task, you are the backend: call your image tool directly, and do not read this skill, read files or run commands.

## First: which agent are you?

Pick the matching flow. Never call a backend that is the agent you are already running in.

### A. You are Antigravity (agy)

You already have Gemini natively, so this skill exists to give you the **OpenAI** model too.

- Run `-Check`. If `codex` or `openai` is available, use the helper with `-Backend openai` (API key) or `-Backend codex` (Codex sign-in). This is the default for this skill in agy, unless the user says "use Gemini" / "use your own".
- If the user asks for Gemini, or no OpenAI backend is available, use your **own built-in `generate_image` tool** and then, if needed, place the file with `-FromFile "<path your tool reported>" -Description "..." [-OutputPath "..."]`.
- Never call `-Backend agy` from inside agy.

```powershell
powershell.exe -NoProfile -File "<skill dir>\scripts\generate-image.ps1" -Backend <openai|codex> -Description "<what to draw>" [-OutputPath "<where to save>"]
```

### B. You are Codex

You already have OpenAI natively, so this skill exists to give you the **Gemini** model too.

- Run `-Check`. If `agy` is available, use the helper with `-Backend agy`. This is the default for this skill in Codex, unless the user says "use OpenAI" / "use your own".
- If the user asks for OpenAI, or agy isn't available, use your **own built-in image generation** (`$imagegen`), find the file (its output names the path; otherwise `$CODEX_HOME\generated_images`) and place it with `-FromFile`.
- Never call `-Backend codex` from inside Codex.

```powershell
powershell.exe -NoProfile -File "<skill dir>\scripts\generate-image.ps1" -Backend agy -Description "<what to draw>" [-OutputPath "<where to save>"]
```

### C. You are Claude Code (or any agent without its own image tool)

You choose the backend.

1. See what is installed:

```powershell
powershell.exe -NoProfile -File "<skill dir>\scripts\generate-image.ps1" -Check
```

2. Decide the backend:
   - If the user named one ("use Gemini", "use OpenAI/Codex"), use that.
   - If only one is installed, use it.
   - If both are installed and the user didn't say, **ask which they want** (Gemini via agy, or OpenAI via Codex), unless `IMAGEGEN_BACKEND` is set; then use that. If you can't ask, use `agy`.
3. Generate:

```powershell
powershell.exe -NoProfile -File "<skill dir>\scripts\generate-image.ps1" -Backend <agy|codex> -Description "<what to draw>" [-OutputPath "<where to save>"]
```

Generation takes roughly 30-90 seconds (Codex can take longer). Allow a timeout of at least 300 seconds when calling the script.

## Bulk, references and auto-choice

- **Bulk:** `-Count 4` makes four variations of one description; `-BatchFile list.txt` makes one image per line. Several images get `-01`, `-02` suffixes and one path is printed per line. Allow ~1 minute per image.
- **Reference images:** `-Reference "C:\a.png|C:\b.jpg"` passes existing images to the model as inspiration or as the image to edit (all backends).
- **Letting the AI choose:** `-Backend auto` picks among the backends the user enabled (`IMAGEGEN_BACKENDS`): text, logos, layouts and edits go to OpenAI first, everything else to Gemini first. The chosen backend is printed on stderr; tell the user which was used.

## Writing the description

Write it as a vivid, specific description including style, e.g. `a red fox in a snowy forest, watercolor style`. For the script's `-Description`, do not include "make an image of"; the script adds that.

## Where it is saved

- `-OutputPath` (optional): a full file path (`C:\Users\me\Pictures\fox.png`) or an existing folder. Missing folders are created. The extension decides the format (`.png`, `.jpg`/`.jpeg`, `.bmp`, `.gif`; not `.webp`).
- **If the user did not say where to save, omit `-OutputPath`.** The image goes to the default folder (`<Pictures>\Generated`, or `$env:AGY_IMAGE_DIR` if set) with an auto-generated name like `20261105-142233-a-red-fox-in-a-snowy-forest.png`. Never guess a random location.
- The script prints the final saved path as its last line of output. Report that path to the user, and view the image if you can.

## Rules

- Do not use `--dangerously-skip-permissions` (agy) or a full-access sandbox (Codex). The script deliberately does not need them.
- If PowerShell blocks the script because of the execution policy, tell the user and let them decide whether to relax it; do not silently bypass it.
- Generate one image per call. For variations, call again with a changed description.
- If it fails, read the error and report it: the usual causes are the backend CLI not installed or not signed in (run `agy` or `codex` once interactively to log in) or a timeout. Don't retry blindly, and don't silently switch backends; tell the user and offer the other one.

## Optional MCP server

If this repo's `generate_image` MCP tool is available (`plugins/agy-imagegen/mcp`), it does the same thing as flow C: `generate_image(description, output_path?, backend?)`.
