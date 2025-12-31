const CACHE_NAME = "pnnx-assets-v1";


const CDN_JS   = "https://mirrors.sdu.edu.cn/ncnn_modelzoo/pnnx/pnnx.js";
const CDN_WASM = "https://mirrors.sdu.edu.cn/ncnn_modelzoo/pnnx/pnnx.wasm";

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    await self.clients.claim();
  })());
});


self.addEventListener("message", (event) => {
  const data = event.data || {};
  if (data.type === "CLEAR_PNNX_CACHE") {
    event.waitUntil(caches.delete(CACHE_NAME));
  }
});

function shouldHandle(requestUrl) {
  try {
    const u = new URL(requestUrl);

    if (u.href === CDN_JS || u.href === CDN_WASM) return true;

    if (u.origin === self.location.origin) {
      if (u.pathname.endsWith("/pnnx.js") || u.pathname.endsWith("/pnnx.wasm")) return true;
    }
  } catch (_) {}
  return false;
}

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  if (!shouldHandle(event.request.url)) return;

  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);

    const cached = await cache.match(event.request, { ignoreSearch: true });
    if (cached) return cached;

    const resp = await fetch(event.request);

    if (resp && resp.ok) {
      try {
        const u = new URL(event.request.url);
        const isWasm = u.pathname.endsWith(".wasm");
        if (isWasm && resp.body && resp.type !== "opaque") {
          const headers = new Headers(resp.headers);
          headers.set("Content-Type", "application/wasm");
          const fixed = new Response(resp.body, {
            status: resp.status,
            statusText: resp.statusText,
            headers,
          });
          await cache.put(event.request, fixed.clone());
          return fixed;
        }
      } catch (_) {}

      await cache.put(event.request, resp.clone());
    }

    return resp;
  })());
});
