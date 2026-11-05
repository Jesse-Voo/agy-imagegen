---
name: image-generation
description: Generate an image from a text description and save it to disk. Uses Gemini (Antigravity CLI or API key), OpenAI (API key), the free Pollinations service or a local model, whichever the user has set up. Use when the user asks to create, generate, draw, or make an image, picture, illustration, logo, icon, or artwork.
---

# Image generation (Gemini, OpenAI, free and local models)

Turns a text description into an image file. Windows + PowerShell. Image backends:

| Backend | Model | Needs |
| --- | --- | --- |
| `agy` | Gemini (via the Antigravity CLI) | `agy` installed and signed in |
| `gemini` | Gemini image models (default `gemini-2.5-flash-image`) and Imagen (`-Model imagen-4.0-generate-001`) via the Gemini API | a Google AI Studio key: `-Login -Provider gemini` once, or `GEMINI_API_KEY` |
| `openai` | OpenAI Images API (default `gpt-image-2`; also `gpt-image-1`, `gpt-image-1-mini`, `dall-e-3` via `-Model`) | an OpenAI API key: `-Login` once, or `OPENAI_API_KEY` |
| `pollinations` | Free public service (default `flux`), no key, no account. Lower quality, small watermark, no reference images, and the anonymous tier is rate-limited (may answer 402/429) | nothing |
| `local` | A local OpenAI-compatible image server | `IMAGEGEN_LOCAL_URL` set |
| `auto` | Picks one of the above for you | `IMAGEGEN_BACKENDS` limits the choice (e.g. `agy,openai,pollinations`) |

ChatGPT/Codex sign-ins cannot generate images (OpenAI doesn't offer image generation to ChatGPT-plan sign-ins, and headless `codex exec` has no image tool), so OpenAI models need an API key. `-Login` is run by the user in their own terminal: never ask them to paste a key into chat.

The helper script is `scripts/generate-image.ps1`, next to this file. Below, `<skill dir>` means this skill's folder.

## Skip this skill when you were launched by it

The helper script starts `agy` headlessly with a prompt like "Call your built-in image generation tool right now ...". If that is your whole task, you are the backend: call your image tool directly, and do not read this skill, read files or run commands.

## First: which agent are you?

### A. You are Antigravity (agy)

You already have Gemini natively.

- By default use your **own built-in `generate_image` tool**, then place the file if needed with `-FromFile "<path your tool reported>" -Description "..." [-OutputPath "..."]`.
- If the user wants a different model (OpenAI, Imagen, a free or local model), run `-Check` and use the helper with that backend (`openai`, `gemini`, `pollinations`, `local`).
- Never call `-Backend agy` from inside agy.

### B. You are Codex

Codex cannot generate images headlessly, so always use the helper. Run `-Check`, then pick a backend that is available: `agy` (Gemini), `gemini`, `openai`, `pollinations` (free, always works) or `local`. Ask the user if several are available and they haven't said.

### C. You are Claude Code (or any agent without its own image tool)

You choose the backend.

1. See what is available:

```powershell
powershell.exe -NoProfile -File "<skill dir>\scripts\generate-image.ps1" -Check
```

2. Decide the backend:
   - If the user named a backend or model ("use Gemini", "use OpenAI", "use Imagen", "something free"), use that.
   - If only one is available, use it.
   - If several are available and the user didn't say, **ask which they want**, unless `IMAGEGEN_BACKEND` is set; then use that. If you can't ask, use `auto`.
3. Generate:

```powershell
powershell.exe -NoProfile -File "<skill dir>\scripts\generate-image.ps1" -Backend <agy|gemini|openai|pollinations|local|auto> [-Model "<model>"] -Description "<what to draw>" [-OutputPath "<where to save>"]
```

Generation takes roughly 10-90 seconds per image. Allow a timeout of at least 300 seconds when calling the script.

## Bulk, references, models and auto-choice

- **Bulk:** `-Count 4` makes four variations of one description; `-BatchFile list.txt` makes one image per line. Several images get `-01`, `-02` suffixes and one path is printed per line. Allow ~1 minute per image.
- **Reference images:** `-Reference "C:\a.png|C:\b.jpg"` passes existing images to the model as inspiration or as the image to edit (`agy`, `gemini` with Gemini models, `openai`, `local`; not `pollinations` or Imagen).
- **Model choice:** `-Model` overrides the default model for `gemini`, `openai`, `pollinations` and `local`.
- **Letting the AI choose:** `-Backend auto` picks among the backends the user enabled (`IMAGEGEN_BACKENDS`): text, logos, layouts and edits go to OpenAI first, everything else to Gemini first, quick drafts to local/free models. The chosen backend is printed on stderr; tell the user which was used.

## Writing the description

Write it as a vivid, specific description including style, e.g. `a red fox in a snowy forest, watercolor style`. For the script's `-Description`, do not include "make an image of"; the script adds that.

## Where it is saved

- `-OutputPath` (optional): a full file path (`C:\Users\me\Pictures\fox.png`) or a folder. Missing folders are created. The extension decides the format (`.png`, `.jpg`/`.jpeg`, `.bmp`, `.gif`; not `.webp`).
- **If the user did not say where to save, omit `-OutputPath`.** The image goes to the default folder (`<Pictures>\Generated`, or `$env:AGY_IMAGE_DIR` if set) with an auto-generated name like `20261105-142233-a-red-fox-in-a-snowy-forest.png`. Never guess a random location.
- The script prints the final saved path as its last line of output. Report that path to the user, and view the image if you can.

## Rules

- Do not use `--dangerously-skip-permissions` (agy). The script deliberately does not need it.
- If PowerShell blocks the script because of the execution policy, tell the user and let them decide whether to relax it; do not silently bypass it.
- Never ask for, accept or type an API key in chat; the user signs in with `-Login` themselves.
- If it fails, read the error and report it: the usual causes are agy not installed or signed in, a missing API key, or a timeout. Don't retry blindly, and don't silently switch backends; tell the user and offer another one.

## Optional MCP server

If this repo's `generate_image` MCP tool is available (`plugins/agy-imagegen/mcp`), it does the same thing as flow C: `generate_image(description, output_path?, backend?, model?, count?, descriptions?, reference_images?)`.

- **It returns the image itself** (a JPEG preview as an image block) as well as the saved path(s), so show it to the user in your reply. The path points to the full-size file.
- **Long generations:** hosts often cut a tool call off at ~60 s, so the tool waits ~45 s and then returns a **job id** while the image keeps generating in the background. When you get a job id, **never call `generate_image` again** (that makes duplicates); call `check_image_job(job_id)` until it returns the image.
- **When you run the script directly** (no MCP), show the result yourself: view the saved file if your tool can display images, and always report the path. `-PreviewFor <file>` prints the path of a small JPEG preview you can open instead of a huge original.
