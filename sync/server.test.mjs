import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createJournalServer } from "./server.mjs";
const token = "only-for-local-integration-tests";
function fixture() {
  return {
    id: "6653d5de-2d04-4025-b739-415a4723c854",
    title: "Склад",
    location: "Этаж 1",
    inspector: "Тест",
    notes: "",
    createdAt: "2026-10-18T10:00:00Z",
    updatedAt: "2026-10-18T10:00:00Z",
    revision: 1,
    remoteRevision: 0,
    checkpoints: [],
    photos: [],
    archived: false,
  };
}
test("sync auth, idempotency, conflict, atomic version and disk restart", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "journal-test-"));
  let server;
  try {
    async function start() {
      server = await createJournalServer({ directory, token });
      await new Promise((r) => server.listen(0, "127.0.0.1", r));
      return `http://127.0.0.1:${server.address().port}`;
    }
    let base = await start();
    const record = fixture();
    const route = `/records/${record.id}`;
    const headers = {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "If-Match": "0",
      "Idempotency-Key": "first",
    };
    assert.equal((await fetch(base + route)).status, 401);
    let result = await fetch(base + route, {
      method: "PUT",
      headers,
      body: JSON.stringify(record),
    });
    assert.equal(result.status, 200);
    assert.equal((await result.json()).record.remoteRevision, 1);
    result = await fetch(base + route, {
      method: "PUT",
      headers,
      body: JSON.stringify(record),
    });
    assert.equal(result.status, 200);
    const reordered = Object.fromEntries(Object.entries(record).reverse());
    result = await fetch(base + route, {
      method: "PUT",
      headers,
      body: JSON.stringify(reordered),
    });
    assert.equal(result.status, 200);
    result = await fetch(base + route, {
      method: "PUT",
      headers,
      body: JSON.stringify({ ...record, title: "Разные данные" }),
    });
    assert.equal(result.status, 409);
    result = await fetch(base + route, {
      method: "PUT",
      headers: { ...headers, "Idempotency-Key": "stale" },
      body: JSON.stringify({ ...record, revision: 2 }),
    });
    assert.equal(result.status, 409);
    result = await fetch(base + route, {
      method: "PUT",
      headers: { ...headers, "If-Match": "1", "Idempotency-Key": "second" },
      body: JSON.stringify({ ...record, revision: 3, remoteRevision: 1 }),
    });
    assert.equal(result.status, 200);
    await new Promise((r) => server.close(r));
    base = await start();
    result = await fetch(base + route, {
      headers: { Authorization: `Bearer ${token}` },
    });
    assert.equal((await result.json()).revision, 3);
    result = await fetch(base + route, {
      method: "PUT",
      headers,
      body: JSON.stringify({ ...record, revision: -1 }),
    });
    assert.equal(result.status, 400);
    result = await fetch(base + route, {
      method: "PUT",
      headers,
      body: JSON.stringify({ ...record, notes: "x".repeat(30001) }),
    });
    assert.equal(result.status, 400);
    result = await fetch(base + route, {
      method: "PUT",
      headers,
      body: JSON.stringify({
        ...record,
        photos: [{ id: crypto.randomUUID(), caption: "", jpegData: "A" }],
      }),
    });
    assert.equal(result.status, 400);
  } finally {
    if (server?.listening) await new Promise((r) => server.close(r));
    await fs.rm(directory, { recursive: true, force: true });
  }
});
