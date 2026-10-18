import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { pathToFileURL } from "node:url";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object")
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canonical(value[key])]),
    );
  return value;
}
export function validateRecord(record, id) {
  if (
    !record ||
    typeof record !== "object" ||
    record.id?.toLowerCase() !== id.toLowerCase()
  )
    throw new Error("Record id mismatch");
  if (
    typeof record.title !== "string" ||
    !record.title.trim() ||
    record.title.length > 200
  )
    throw new Error("Invalid title");
  if (
    !Number.isSafeInteger(record.revision) ||
    record.revision < 1 ||
    !Number.isSafeInteger(record.remoteRevision) ||
    record.remoteRevision < 0 ||
    record.remoteRevision >= record.revision
  )
    throw new Error("Invalid revisions");
  for (const [key, limit] of Object.entries({
    location: 500,
    inspector: 200,
    notes: 30000,
  }))
    if (typeof record[key] !== "string" || [...record[key]].length > limit)
      throw new Error(`Invalid ${key}`);
  if (
    !Number.isFinite(Date.parse(record.createdAt)) ||
    !Number.isFinite(Date.parse(record.updatedAt))
  )
    throw new Error("Invalid dates");
  if (
    !Array.isArray(record.checkpoints) ||
    record.checkpoints.length > 200 ||
    !Array.isArray(record.photos) ||
    record.photos.length > 30
  )
    throw new Error("Invalid collections");
  const ids = new Set();
  for (const item of record.checkpoints) {
    if (
      !uuid.test(item.id) ||
      ids.has(item.id) ||
      typeof item.title !== "string" ||
      !item.title.trim() ||
      [...item.title].length > 300 ||
      typeof item.note !== "string" ||
      [...item.note].length > 10000 ||
      !["pending", "passed", "attention", "notApplicable"].includes(item.state)
    )
      throw new Error("Invalid checkpoint");
    ids.add(item.id);
  }
  const photos = new Set();
  for (const photo of record.photos) {
    if (
      !uuid.test(photo.id) ||
      photos.has(photo.id) ||
      typeof photo.caption !== "string" ||
      [...photo.caption].length > 1000 ||
      typeof photo.jpegData !== "string" ||
      photo.jpegData.length > 6_666_668 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(
        photo.jpegData,
      ) ||
      Buffer.from(photo.jpegData, "base64").length > 5_000_000 ||
      Buffer.from(photo.jpegData, "base64").toString("base64") !==
        photo.jpegData
    )
      throw new Error("Invalid photo");
    photos.add(photo.id);
  }
  if (typeof record.archived !== "boolean")
    throw new Error("Invalid archive flag");
}
export async function createJournalServer({ directory, token }) {
  if (!token || token.length < 16)
    throw new Error("JOURNAL_TOKEN must have at least 16 characters");
  await fs.mkdir(directory, { recursive: true });
  let serial = Promise.resolve();
  const server = http.createServer(async (req, res) => {
    const send = (code, body) => {
      res.writeHead(code, {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
      });
      res.end(JSON.stringify(body));
    };
    if (req.method === "GET" && req.url === "/health") {
      send(200, { ok: true, version: "0.1.0-rc.1" });
      return;
    }
    const supplied = Buffer.from(req.headers.authorization ?? "");
    const expected = Buffer.from(`Bearer ${token}`);
    if (
      supplied.length !== expected.length ||
      !crypto.timingSafeEqual(supplied, expected)
    ) {
      send(401, { error: "Unauthorized" });
      return;
    }
    const match = /^\/records\/([^/?]+)$/.exec(req.url ?? "");
    if (!match || !uuid.test(match[1])) {
      send(404, { error: "Not found" });
      return;
    }
    const id = match[1];
    const file = path.join(directory, `${id.toLowerCase()}.json`);
    async function read() {
      try {
        return JSON.parse(await fs.readFile(file, "utf8"));
      } catch (e) {
        if (e.code === "ENOENT") return null;
        throw e;
      }
    }
    try {
      if (req.method === "GET") {
        await serial;
        const stored = await read();
        send(stored ? 200 : 404, stored?.envelope ?? { error: "Not found" });
        return;
      }
      if (req.method !== "PUT") {
        send(405, { error: "Method not allowed" });
        return;
      }
      let size = 0;
      const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 100_000_000) {
          send(413, { error: "Body exceeds 100 MB" });
          return;
        }
        chunks.push(chunk);
      }
      let record;
      try {
        record = JSON.parse(Buffer.concat(chunks));
        validateRecord(record, id);
      } catch (e) {
        send(400, { error: e.message });
        return;
      }
      const expectedRevision = Number(req.headers["if-match"]);
      const requestKey = req.headers["idempotency-key"];
      if (
        req.headers["if-match"] === undefined ||
        !Number.isSafeInteger(expectedRevision) ||
        expectedRevision < 0 ||
        typeof requestKey !== "string" ||
        requestKey.length > 200
      ) {
        send(400, { error: "If-Match and Idempotency-Key required" });
        return;
      }
      const digest = crypto
        .createHash("sha256")
        .update(JSON.stringify(canonical(record)))
        .digest("hex");
      const operation = serial.then(async () => {
        const stored = await read();
        if (stored?.key === requestKey) {
          if (stored.digest === digest) return [200, stored.envelope];
          return [409, { error: "Idempotency key reused with different data" }];
        }
        if (
          (stored?.envelope.revision ?? 0) !== expectedRevision ||
          record.remoteRevision !== expectedRevision ||
          record.revision <= expectedRevision
        )
          return [409, { error: "Revision conflict" }];
        const envelope = {
          revision: record.revision,
          record: { ...record, remoteRevision: record.revision },
        };
        const temp = `${file}.${crypto.randomUUID()}.tmp`;
        const handle = await fs.open(temp, "wx", 0o600);
        try {
          await handle.writeFile(
            JSON.stringify({ key: requestKey, digest, envelope }),
          );
          await handle.sync();
        } finally {
          await handle.close();
        }
        try {
          await fs.rename(temp, file);
        } catch (e) {
          await fs.rm(temp, { force: true });
          throw e;
        }
        return [200, envelope];
      });
      serial = operation.then(
        () => {},
        () => {},
      );
      const [code, body] = await operation;
      send(code, body);
    } catch {
      send(500, { error: "Storage unavailable; request was not acknowledged" });
    }
  });
  return server;
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const token = process.env.JOURNAL_TOKEN;
  if (!token) {
    console.error("Set JOURNAL_TOKEN (at least 16 characters) before starting");
    process.exitCode = 1;
  } else {
    const server = await createJournalServer({
      directory: path.resolve(process.env.JOURNAL_DATA ?? "sync-data"),
      token,
    });
    server.listen(
      Number(process.env.PORT ?? 4420),
      process.env.HOST ?? "127.0.0.1",
      () => console.log("Полевой журнал: sync API http://127.0.0.1:4420"),
    );
    for (const signal of ["SIGINT", "SIGTERM"])
      process.on(signal, () => server.close(() => process.exit(0)));
  }
}
