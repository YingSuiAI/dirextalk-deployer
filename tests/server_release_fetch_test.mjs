import assert from "node:assert/strict";
import { fetchBytes, latestReleaseAPI } from "../scripts/lib/server-release-resolver.mjs";

const assetURL = "https://github.com/YingSuiAI/dirextalk-message-server/releases/download/v1.1.0/release-manifest.json";
const cdnURL = "https://release-assets.githubusercontent.com/github-production-release-asset/example?sp=r&sig=test";

function response({ status = 200, headers = {}, chunks = [] } = {}) {
  let index = 0;
  const state = { reads: 0, cancelled: false };
  return {
    status,
    ok: status >= 200 && status < 300,
    headers: { get: (name) => headers[name.toLowerCase()] ?? null },
    body: {
      getReader() {
        return {
          async read() {
            state.reads += 1;
            if (index >= chunks.length) return { done: true };
            return { done: false, value: chunks[index++] };
          },
          async cancel() { state.cancelled = true; },
        };
      },
    },
    state,
  };
}

{
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, options });
    if (url === assetURL) return response({ status: 302, headers: { location: cdnURL } });
    if (url === cdnURL) return response({ chunks: [Buffer.from("manifest")] });
    throw new Error(`unexpected URL ${url}`);
  };
  const data = await fetchBytes(assetURL, { fetchImpl });
  assert.equal(data.toString(), "manifest");
  assert.deepEqual(calls.map(({ url }) => url), [assetURL, cdnURL]);
  assert.ok(calls.every(({ options }) => options.redirect === "manual"));
}

await assert.rejects(
  () => fetchBytes(latestReleaseAPI, {
    fetchImpl: async () => response({ status: 302, headers: { location: cdnURL } }),
  }),
  /metadata.*redirect|redirect.*metadata/i,
);

for (const location of [
  "http://release-assets.githubusercontent.com/object",
  "https://user@release-assets.githubusercontent.com/object",
  "https://release-assets.githubusercontent.com/object#fragment",
  "https://localhost/object",
  "https://127.0.0.1/object",
  "https://attacker.example/object",
]) {
  await assert.rejects(
    () => fetchBytes(assetURL, {
      fetchImpl: async () => response({ status: 302, headers: { location } }),
    }),
    /redirect|URL|host|HTTPS/i,
  );
}

{
  const oversized = response({ headers: { "content-length": String(1024 * 1024 + 1) }, chunks: [Buffer.from("must not be read")] });
  await assert.rejects(() => fetchBytes(assetURL, { fetchImpl: async () => oversized }), /Content-Length|exceeds/i);
  assert.equal(oversized.state.reads, 0);
}

{
  const oversized = response({ chunks: [Buffer.alloc(1024 * 1024), Buffer.from("x")] });
  await assert.rejects(() => fetchBytes(assetURL, { fetchImpl: async () => oversized }), /exceeds/i);
  assert.equal(oversized.state.cancelled, true);
}

await assert.rejects(
  () => fetchBytes(assetURL, {
    timeoutMs: 5,
    fetchImpl: async (_url, { signal }) => new Promise((_resolve, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
    }),
  }),
  /timed out|abort/i,
);

{
  let redirects = 0;
  await assert.rejects(
    () => fetchBytes(assetURL, {
      maxRedirects: 2,
      fetchImpl: async () => {
        redirects += 1;
        return response({ status: 302, headers: { location: cdnURL } });
      },
    }),
    /too many redirects/i,
  );
  assert.equal(redirects, 3);
}

console.log("server release bounded fetch ok");
