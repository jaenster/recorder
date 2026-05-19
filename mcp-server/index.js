#!/usr/bin/env node
// MCP server: read-only access to ~/Recordings/ for Claude.
// Tools:
//   list_recordings              — newest first
//   get_latest_transcript        — content of the most recent .txt
//   get_transcript(name)         — content of voice-<ts>.txt
//   get_recording_info(name)     — size, mtime, duration, paths
//   open_recordings_folder       — opens ~/Recordings in Finder

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { promises as fs } from "node:fs";
import { spawn } from "node:child_process";
import path from "node:path";
import os from "node:os";

const RECORDINGS_DIR =
  process.env.RECORDER_DIR || path.join(os.homedir(), "Recordings");

function pretty(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

async function listVoiceRecordings() {
  try {
    await fs.access(RECORDINGS_DIR);
  } catch {
    return [];
  }
  const all = await fs.readdir(RECORDINGS_DIR);
  const audio = all.filter(
    (n) => n.startsWith("voice-") && n.endsWith(".m4a")
  );
  const items = await Promise.all(
    audio.map(async (name) => {
      const audioPath = path.join(RECORDINGS_DIR, name);
      const stat = await fs.stat(audioPath);
      const transcriptName = name.replace(/\.m4a$/, ".txt");
      const transcriptPath = path.join(RECORDINGS_DIR, transcriptName);
      let transcriptExists = false;
      try {
        await fs.access(transcriptPath);
        transcriptExists = true;
      } catch {}
      return {
        name,
        audioPath,
        transcriptPath,
        transcriptExists,
        size: stat.size,
        mtime: stat.mtimeMs,
      };
    })
  );
  return items.sort((a, b) => b.mtime - a.mtime);
}

async function readTranscript(transcriptPath) {
  try {
    return await fs.readFile(transcriptPath, "utf8");
  } catch (err) {
    if (err.code === "ENOENT") return null;
    throw err;
  }
}

const tools = [
  {
    name: "list_recordings",
    description:
      "List voice recordings in ~/Recordings/, newest first. Each entry " +
      "shows the .m4a name, file size, modification time, and whether a " +
      "transcript .txt exists alongside it.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "integer",
          description: "Max entries to return (default 20).",
          default: 20,
        },
      },
    },
  },
  {
    name: "get_latest_transcript",
    description:
      "Return the full text of the most recent transcript (.txt) in " +
      "~/Recordings/. Transcripts are speaker-labeled lines like " +
      "'[mm:ss] ME: ...' / '[mm:ss] THEM: ...'.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "get_transcript",
    description:
      "Return the text of a specific transcript by recording name. " +
      "Accepts either the .m4a filename or its .txt counterpart.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "e.g. voice-2026-05-18-150412.m4a" },
      },
      required: ["name"],
    },
  },
  {
    name: "get_recording_info",
    description:
      "Return metadata for a specific recording: paths, file size, " +
      "modification time, whether a transcript exists.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Recording filename (.m4a)." },
      },
      required: ["name"],
    },
  },
  {
    name: "open_recordings_folder",
    description: "Open ~/Recordings in Finder on the user's Mac.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "search_recordings",
    description:
      "Full-text search across all transcripts (.txt) and summaries " +
      "(.summary.md) in ~/Recordings/. Returns matching filenames with " +
      "snippet context. Case-insensitive substring match.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Text to search for." },
        max_results: {
          type: "integer",
          description: "Max files to return (default 10).",
          default: 10,
        },
      },
      required: ["query"],
    },
  },
  {
    name: "get_summary",
    description:
      "Return the markdown summary for a specific recording, by recording " +
      "name (.m4a) or summary name (.summary.md).",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "e.g. voice-2026-05-18-150412.m4a" },
      },
      required: ["name"],
    },
  },
  {
    name: "get_latest_summary",
    description:
      "Return the markdown summary of the most recent recording, if " +
      "Apple Intelligence summarization was enabled and available.",
    inputSchema: { type: "object", properties: {} },
  },
];

const server = new Server(
  { name: "recorder", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args = {} } = request.params;

  try {
    switch (name) {
      case "list_recordings": {
        const limit = args.limit ?? 20;
        const items = (await listVoiceRecordings()).slice(0, limit);
        if (items.length === 0) {
          return text("(no recordings yet)");
        }
        const lines = items.map((item) => {
          const when = new Date(item.mtime).toISOString().replace("T", " ").slice(0, 19);
          const tx = item.transcriptExists ? "✓ transcript" : "✗ no transcript";
          return `${item.name}  ${pretty(item.size)}  ${when}  ${tx}`;
        });
        return text(lines.join("\n"));
      }

      case "get_latest_transcript": {
        const items = await listVoiceRecordings();
        const latest = items.find((i) => i.transcriptExists);
        if (!latest) return text("(no transcripts yet)");
        const body = await readTranscript(latest.transcriptPath);
        return text(`# ${latest.name.replace(/\.m4a$/, ".txt")}\n\n${body ?? ""}`);
      }

      case "get_transcript": {
        if (!args.name) return errorText("missing 'name'");
        const baseName = args.name.replace(/\.m4a$/, "").replace(/\.txt$/, "");
        const transcriptPath = path.join(RECORDINGS_DIR, `${baseName}.txt`);
        const body = await readTranscript(transcriptPath);
        if (body == null) {
          return errorText(
            `No transcript at ${transcriptPath}. Has the recording been transcribed yet?`
          );
        }
        return text(body);
      }

      case "get_recording_info": {
        if (!args.name) return errorText("missing 'name'");
        const items = await listVoiceRecordings();
        const match = items.find((i) => i.name === args.name);
        if (!match) return errorText(`No recording named ${args.name}`);
        const lines = [
          `name: ${match.name}`,
          `audio: ${match.audioPath}`,
          `transcript: ${match.transcriptPath}${match.transcriptExists ? "" : "  (missing)"}`,
          `size: ${pretty(match.size)} (${match.size} bytes)`,
          `modified: ${new Date(match.mtime).toISOString()}`,
        ];
        return text(lines.join("\n"));
      }

      case "search_recordings": {
        if (!args.query || typeof args.query !== "string") {
          return errorText("missing 'query'");
        }
        const maxResults = args.max_results ?? 10;
        const needle = args.query.toLowerCase();
        const entries = await fs.readdir(RECORDINGS_DIR).catch(() => []);
        const candidates = entries.filter(
          (n) =>
            n.startsWith("voice-") &&
            (n.endsWith(".txt") || n.endsWith(".summary.md"))
        );
        const matches = [];
        for (const name of candidates) {
          const filePath = path.join(RECORDINGS_DIR, name);
          let body;
          try {
            body = await fs.readFile(filePath, "utf8");
          } catch {
            continue;
          }
          const idx = body.toLowerCase().indexOf(needle);
          if (idx < 0) continue;
          const start = Math.max(0, idx - 80);
          const end = Math.min(body.length, idx + needle.length + 80);
          const snippet = body
            .slice(start, end)
            .replace(/\s+/g, " ")
            .trim();
          const stat = await fs.stat(filePath);
          matches.push({ name, mtime: stat.mtimeMs, snippet });
        }
        matches.sort((a, b) => b.mtime - a.mtime);
        const trimmed = matches.slice(0, maxResults);
        if (trimmed.length === 0) {
          return text(`No matches for "${args.query}".`);
        }
        const lines = trimmed.map((m) => {
          const when = new Date(m.mtime).toISOString().slice(0, 10);
          return `${m.name}  (${when})\n  …${m.snippet}…`;
        });
        return text(lines.join("\n\n"));
      }

      case "get_summary": {
        if (!args.name) return errorText("missing 'name'");
        const baseName = args.name
          .replace(/\.summary\.md$/, "")
          .replace(/\.m4a$/, "")
          .replace(/\.txt$/, "");
        const summaryPath = path.join(RECORDINGS_DIR, `${baseName}.summary.md`);
        try {
          const body = await fs.readFile(summaryPath, "utf8");
          return text(body);
        } catch {
          return errorText(`No summary at ${summaryPath}.`);
        }
      }

      case "get_latest_summary": {
        const all = await fs.readdir(RECORDINGS_DIR).catch(() => []);
        const summaries = all.filter((n) => n.endsWith(".summary.md"));
        if (summaries.length === 0) return text("(no summaries yet)");
        const ranked = await Promise.all(
          summaries.map(async (n) => {
            const p = path.join(RECORDINGS_DIR, n);
            const s = await fs.stat(p);
            return { name: n, path: p, mtime: s.mtimeMs };
          })
        );
        ranked.sort((a, b) => b.mtime - a.mtime);
        const top = ranked[0];
        const body = await fs.readFile(top.path, "utf8");
        return text(`# ${top.name}\n\n${body}`);
      }

      case "open_recordings_folder": {
        await fs.mkdir(RECORDINGS_DIR, { recursive: true });
        spawn("open", [RECORDINGS_DIR], { detached: true, stdio: "ignore" }).unref();
        return text(`Opened ${RECORDINGS_DIR}`);
      }

      default:
        return errorText(`Unknown tool: ${name}`);
    }
  } catch (err) {
    return errorText(`${name} failed: ${err.message}`);
  }
});

function text(body) {
  return { content: [{ type: "text", text: body }] };
}

function errorText(body) {
  return { content: [{ type: "text", text: body }], isError: true };
}

const transport = new StdioServerTransport();
await server.connect(transport);
