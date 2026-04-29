// sw.js
const SRC_MODE = (new URL(self.location.href)).searchParams.get("src") || "cdn"; // "cdn" | "origin"
const CACHE_NAME = `pnnx-assets-v2-${SRC_MODE}`;

const CDN_JS   = "https://mirrors.sdu.edu.cn/ncnn_modelzoo/pnnx/pnnx.js";
const CDN_WASM = "https://mirrors.sdu.edu.cn/ncnn_modelzoo/pnnx/pnnx.wasm";

const ORIGIN_JS   = "./pnnx.js";
const ORIGIN_WASM = "./pnnx.wasm";

function getAssetList() {
  if (SRC_MODE === "origin") return [ORIGIN_JS, ORIGIN_WASM];
  return [CDN_JS, CDN_WASM];
}

self.addEventListener("install", (event) => {
  self.skipWaiting();
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    await cache.addAll(getAssetList());
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.map(k => (k !== CACHE_NAME) ? caches.delete(k) : Promise.resolve()));
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

    if (SRC_MODE === "cdn") {
      return (u.href === CDN_JS || u.href === CDN_WASM);
    }

    // origin 模式：只处理本站的 pnnx.js/pnnx.wasm
    if (u.origin === self.location.origin) {
      return u.pathname.endsWith("/pnnx.js") || u.pathname.endsWith("/pnnx.wasm");
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
          // wasm 类型修正（某些镜像站/代理可能缺失 content-type）
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
