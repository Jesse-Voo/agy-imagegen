import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { spawn } from "node:child_process";
import { existsSync, writeFileSync, readFileSync, unlinkSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const SCRIPT_PATH = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "skills",
  "image-generation",
  "scripts",
  "generate-image.ps1"
);

// Hosts often give a tool call only ~60 s. Image generation can take longer, so a call waits up to
// this long and otherwise returns a job id that check_image_job can collect later.
const WAIT_MS = Number(process.env.IMAGEGEN_MCP_WAIT_SECONDS || 45) * 1000;
const MAX_PREVIEWS = 4;

const server = new McpServer({
  name: "generate-image",
  version: "1.4.0",
});

function runPowerShell(args) {
  return new Promise((resolve) => {
    const proc = spawn("powershell.exe", ["-NoProfile", "-File", SCRIPT_PATH, ...args], { windowsHide: true });
    let stdout = "";
    let stderr = "";
    proc.stdout.on("data", (c) => (stdout += c.toString()));
    proc.stderr.on("data", (c) => (stderr += c.toString()));
    proc.on("close", (code) => resolve({ code, stderr, stdout }));
    proc.on("error", (err) => resolve({ code: -1, stderr: String(err), stdout: "" }));
  });
}

// A small JPEG copy of each image, returned as MCP image content so the chat can display it.
async function previewBlock(file) {
  try {
    const r = await runPowerShell(["-PreviewFor", file]);
    const preview = r.stdout.trim().split(/\r?\n/).pop();
    if (preview && existsSync(preview)) {
      const data = readFileSync(preview).toString("base64");
      try {
        unlinkSync(preview);
      } catch {}
      return { type: "image", data, mimeType: "image/jpeg" };
    }
  } catch {}
  return null;
}

async function buildResult(result) {
  // The script prints one saved path per line on stdout (progress and errors go to stderr).
  const saved = result.stdout
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && existsSync(l));

  if (saved.length === 0) {
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

  const note = result.code !== 0 ? `\nSome images failed:\n${result.stderr}` : "";
  const content = [
    {
      type: "text",
      text: `Generated ${saved.length} image${saved.length > 1 ? "s" : ""} (shown below; full-size files):\n${saved.join("\n")}${note}`,
    },
  ];
  for (const file of saved.slice(0, MAX_PREVIEWS)) {
    const block = await previewBlock(file);
    if (block) content.push(block);
  }
  return { content };
}

// job id -> { promise, result? }
const jobs = new Map();

function startJob(args) {
  const id = randomUUID().slice(0, 8);
  const job = { startedAt: Date.now(), done: false, result: null };
  job.promise = runPowerShell(args).then((r) => {
    job.done = true;
    job.result = r;
    return r;
  });
  jobs.set(id, job);
  // Forget old jobs after an hour.
  setTimeout(() => jobs.delete(id), 3600 * 1000).unref();
  return { id, job };
}

async function waitForJob(id, job) {
  const timeout = new Promise((resolve) => setTimeout(() => resolve(null), WAIT_MS));
  const finished = await Promise.race([job.promise, timeout]);
  if (finished) return buildResult(finished);
  const secs = Math.round((Date.now() - job.startedAt) / 1000);
  return {
    content: [
      {
        type: "text",
        text:
          `Still generating (job ${id}, ${secs}s so far). It is running in the background and will finish on its own. ` +
          `Do NOT call generate_image again (that would make a duplicate). Call check_image_job with job_id "${id}" in a bit to get the image.`,
      },
    ],
  };
}

server.registerTool(
  "generate_image",
  {
    title: "Generate image",
    description:
      "Generate one or more images and save them to disk. Backends: 'agy' (Gemini via Antigravity CLI), " +
      "'gemini' (Gemini API / Imagen, needs a key), 'openai' (OpenAI Images API, needs a key), 'pollinations' (free, no key), " +
      "'local' (local OpenAI-compatible image server, IMAGEGEN_LOCAL_URL) or 'auto' (picks from the backends " +
      "the user enabled). Supports bulk (count, or descriptions for several different images) and " +
      "reference_images for inspiration/editing. Copies the results to output_path. If no output_path " +
      "is given, saves to the default folder (<Pictures>\\Generated, or AGY_IMAGE_DIR) " +
      "with an auto-generated filename. Returns the saved path(s) AND the image itself so it can be shown in the chat. " +
      "Generation can take a minute or more: if it isn't done within ~45 s this returns a job id; then call " +
      "check_image_job instead of generating again.",
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
        .enum(["agy", "gemini", "openai", "pollinations", "local", "auto"])
        .optional()
        .describe(
          "Optional. 'agy' = Gemini via Antigravity, 'gemini' = Gemini API/Imagen, 'openai' = OpenAI API key, 'pollinations' = free, " +
            "'local' = local server, 'auto' = pick among the user's enabled backends. " +
            "Omit to use IMAGEGEN_BACKEND or the default (agy). Ask the user if several are available and they have a preference."
        ),
      model: z
        .string()
        .optional()
        .describe("Optional. Model name for gemini/openai/pollinations/local, e.g. gpt-image-1-mini, imagen-4.0-generate-001, flux."),
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
  async ({ description, output_path, backend, model, count, descriptions, reference_images }) => {
    const args = ["-Description", description];
    if (output_path) args.push("-OutputPath", output_path);
    if (backend) args.push("-Backend", backend);
    if (model) args.push("-Model", model);
    if (count && count > 1) args.push("-Count", String(count));
    if (reference_images && reference_images.length) args.push("-Reference", reference_images.join("|"));
    if (descriptions && descriptions.length) {
      const batch = path.join(os.tmpdir(), `agy-imagegen-batch-${Date.now()}.txt`);
      writeFileSync(batch, descriptions.map((d) => d.replace(/\s+/g, " ").trim()).join(String.fromCharCode(10)), "utf8");
      args.push("-BatchFile", batch);
    }

    const { id, job } = startJob(args);
    return waitForJob(id, job);
  }
);

server.registerTool(
  "check_image_job",
  {
    title: "Check image job",
    description:
      "Collect the result of a generate_image call that returned a job id because it was still running. " +
      "Waits up to ~45 s; if it still isn't done it says so, and you can call this again. Returns the saved path(s) and the image.",
    inputSchema: {
      job_id: z.string().describe("The job id returned by generate_image."),
    },
  },
  async ({ job_id }) => {
    const job = jobs.get(job_id);
    if (!job) {
      return {
        isError: true,
        content: [
          {
            type: "text",
            text: `No job "${job_id}" (unknown, or this server restarted). Check the default folder (<Pictures>\\Generated) for the file before generating again.`,
          },
        ],
      };
    }
    return waitForJob(job_id, job);
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
