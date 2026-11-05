import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { spawn } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "skills",
  "image-generation",
  "scripts",
  "generate-image.ps1"
);

const server = new McpServer({
  name: "generate-image",
  version: "1.2.0",
});

server.registerTool(
  "generate_image",
  {
    title: "Generate image",
    description:
      "Generate one or more images and save them to disk. Backends: 'agy' (Gemini via Antigravity CLI), " +
      "'codex' (OpenAI gpt-image-2 via Codex CLI), 'openai' (OpenAI Images API, needs OPENAI_API_KEY), " +
      "'local' (local OpenAI-compatible image server, IMAGEGEN_LOCAL_URL) or 'auto' (picks from the backends " +
      "the user enabled). Supports bulk (count, or descriptions for several different images) and " +
      "reference_images for inspiration/editing. Runs headlessly and copies the results to output_path. If no output_path " +
      "is given, saves to the default folder (<Pictures>\\Generated, or AGY_IMAGE_DIR) " +
      "with an auto-generated filename. Returns the saved path(s). Takes roughly a minute per image.",
    inputSchema: {
      description: z
        .string()
        .describe("What the image should depict, e.g. 'a red fox in a snowy forest, watercolor style'"),
      output_path: z
        .string()
        .optional()
        .describe(
          "Optional. Full destination path including filename, e.g. C:\\Users\\me\\Pictures\\fox.png. " +
            "Omit it if the user didn't say where to save. Missing parent folders are created."
        ),
      backend: z
        .enum(["agy", "codex", "openai", "local", "auto"])
        .optional()
        .describe(
          "Optional. 'agy' = Gemini, 'codex' = OpenAI via Codex CLI, 'openai' = OpenAI API key, " +
            "'local' = local server, 'auto' = pick among the user's enabled backends. " +
            "Omit to use IMAGEGEN_BACKEND or the default (agy). Ask the user if several are available and they have a preference."
        ),
      count: z
        .number()
        .int()
        .min(1)
        .max(10)
        .optional()
        .describe("Optional. Make this many variations of description (bulk). Default 1."),
      descriptions: z
        .array(z.string())
        .max(20)
        .optional()
        .describe("Optional. Bulk: one image per entry (use instead of description; description is still required, use a short summary)."),
      reference_images: z
        .array(z.string())
        .optional()
        .describe("Optional. Paths of existing images to use as inspiration or as the image to edit."),
    },
  },
  async ({ description, output_path, backend, count, descriptions, reference_images }) => {
    const args = ["-NoProfile", "-File", SCRIPT_PATH, "-Description", description];
    if (output_path) args.push("-OutputPath", output_path);
    if (backend) args.push("-Backend", backend);
    if (count && count > 1) args.push("-Count", String(count));
    if (reference_images && reference_images.length) args.push("-Reference", reference_images.join("|"));
    if (descriptions && descriptions.length) {
      const batch = path.join(os.tmpdir(), `agy-imagegen-batch-${Date.now()}.txt`);
      writeFileSync(batch, descriptions.map((d) => d.replace(/\s+/g, " ").trim()).join(String.fromCharCode(10)), "utf8");
      args.push("-BatchFile", batch);
    }

    const result = await new Promise((resolve) => {
      const proc = spawn("powershell.exe", args, { windowsHide: true });

      let stdout = "";
      proc.stdout.on("data", (chunk) => {
        stdout += chunk.toString();
      });

      let stderr = "";
      proc.stderr.on("data", (chunk) => {
        stderr += chunk.toString();
      });

      proc.on("close", (code) => resolve({ code, stderr, stdout }));
      proc.on("error", (err) => resolve({ code: -1, stderr: String(err), stdout: "" }));
    });

    // The script prints one saved path per line on stdout (progress and errors go to stderr).
    const saved = result.stdout
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter((l) => l && existsSync(l));

    if (saved.length > 0) {
      const note = result.code !== 0 ? `\nSome images failed:\n${result.stderr}` : "";
      return {
        content: [
          {
            type: "text",
            text: `Generated ${saved.length} image${saved.length > 1 ? "s" : ""}:\n${saved.join("\n")}${note}`,
          },
        ],
      };
    }

    return {
      isError: true,
      content: [
        {
          type: "text",
          text: `Image was not found after the run finished (exit code ${result.code}).${
            result.stderr ? `\nStderr: ${result.stderr}` : ""
          }`,
        },
      ],
    };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
