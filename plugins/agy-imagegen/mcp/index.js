import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
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
  version: "1.0.0",
});

server.registerTool(
  "generate_image",
  {
    title: "Generate image",
    description:
      "Generate an image using the Antigravity CLI (agy) and save it to disk. " +
      "Runs agy headlessly and copies the result to output_path. If no output_path " +
      "is given, saves to the default folder (<Pictures>\\Generated, or AGY_IMAGE_DIR) " +
      "with an auto-generated filename. Returns the saved path. Can take a minute or two.",
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
    },
  },
  async ({ description, output_path }) => {
    const args = ["-NoProfile", "-File", SCRIPT_PATH, "-Description", description];
    if (output_path) args.push("-OutputPath", output_path);

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

    // The script prints the final saved path as its last stdout line.
    const savedPath = result.stdout.trim().split(/\r?\n/).pop() || output_path;

    if (savedPath && existsSync(savedPath)) {
      return {
        content: [{ type: "text", text: `Image generated successfully at ${savedPath}` }],
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
