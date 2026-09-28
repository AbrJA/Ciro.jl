// Ciro.jl playground — vanilla JS, no dependencies.

const $ = (id) => document.getElementById(id);
const PORTS = window.CIRO_PORTS ?? { async: Number(location.port), sync: Number(location.port) + 1 };
const THINK_MS = window.CIRO_THINK_MS ?? 400;

const state = { executor: "async", es: null, reader: null };

const base = () => `${location.protocol}//${location.hostname}:${PORTS[state.executor]}`;
const token = () => $("token").value.trim();

async function request(path, opts = {}, timeoutMs = 15000) {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const res = await fetch(base() + path, { ...opts, signal: ac.signal });
    return { status: res.status, body: await res.text(), ms: 0 };
  } catch (err) {
    return { status: 0, body: `network error: ${err.message}`, ms: 0 };
  } finally {
    clearTimeout(timer);
  }
}

const admin = (path, opts = {}) =>
  request(path, { ...opts, headers: { "X-Admin-Token": token(), ...(opts.headers ?? {}) } });

// Probes, metrics, prometheus

async function refreshProbes() {
  const h = await request("/healthz");
  $("health").textContent = h.status === 200 ? "live" : "down";
  const r = await request("/readyz");
  const ready = $("ready");
  ready.textContent = r.status === 200 ? "ready" : r.status === 503 ? "maintenance (503)" : "unknown";
  ready.classList.toggle("warn", r.status !== 200);
  $("meta").textContent = `${state.executor} :${PORTS[state.executor]}`;
}

async function refreshMetrics() {
  const { status, body } = await request("/api/metrics");
  if (status !== 200) {
    $("metrics").innerHTML = `<div><span>server</span><b>unreachable</b></div>`;
    return;
  }
  const m = JSON.parse(body);
  const cells = [
    ["requests", m.requests], ["responses", m.responses],
    ["2xx", m.status_2xx], ["4xx", m.status_4xx], ["5xx", m.status_5xx],
    ["exceptions", m.exceptions], ["bytes in", m.bytes_in], ["bytes out", m.bytes_out],
  ];
  $("metrics").innerHTML = cells
    .map(([k, v]) => `<div><span>${k}</span><b>${Number(v).toLocaleString()}</b></div>`)
    .join("");
}

async function refreshPrometheus() {
  const { status, body } = await request("/metrics");
  $("prom").textContent = status === 200
    ? body.split("\n").slice(0, 11).join("\n") + "\n…"
    : `HTTP ${status}`;
}

async function refreshLog() {
  const { status, body } = await admin("/admin/log/tail");
  const log = $("log");
  if (status !== 200) {
    log.innerHTML = `<div class="muted">access log needs the admin token (${status})</div>`;
    return;
  }
  const { lines } = JSON.parse(body);
  log.innerHTML = lines.length
    ? lines.slice().reverse().map((l) => `<div>${l.replace(/</g, "&lt;")}</div>`).join("")
    : '<div class="muted">no requests yet</div>';
}

// Generate: SSE deltas and chunked text

function genQuery() {
  return `prompt=${encodeURIComponent($("prompt").value)}&style=${$("style").value}`;
}

function abortStream() {
  if (state.es) { state.es.close(); state.es = null; }
  if (state.reader) { state.reader.cancel().catch(() => {}); state.reader = null; }
}

function streamSSE() {
  abortStream();
  const out = $("gen-out");
  out.textContent = "";
  const es = new EventSource(`${base()}/api/v1/generate?${genQuery()}`);
  state.es = es;
  es.addEventListener("delta", (ev) => { out.textContent += JSON.parse(ev.data).text; });
  es.addEventListener("done", (ev) => {
    out.textContent = JSON.parse(ev.data).text;
    es.close();
    state.es = null;
  });
  es.onerror = () => {
    if (state.es === es) {
      out.textContent +=
        `\n[stream error — the ${state.executor} server may not support streaming (needs AsyncExecutor)]`;
      es.close();
      state.es = null;
    }
  };
}

async function streamTxt() {
  abortStream();
  const out = $("gen-out");
  out.textContent = "";
  try {
    const res = await fetch(`${base()}/api/v1/generate.txt?${genQuery()}`);
    if (!res.ok) { out.textContent = `HTTP ${res.status}`; return; }
    const reader = res.body.getReader();
    state.reader = reader;
    const dec = new TextDecoder();
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      out.textContent += dec.decode(value, { stream: true });
    }
  } catch (err) {
    out.textContent += `\n[${err.message}]`;
  } finally {
    state.reader = null;
  }
}

// Predict: slow handler, concurrency, async vs sync

async function predict(n = 1) {
  const body = $("features").value;
  const model = $("model").value;
  const t0 = performance.now();
  const results = await Promise.all(Array.from({ length: n }, () =>
    request(`/api/v1/predict?model=${model}`, { method: "POST", body }, 30000)));
  const ms = Math.round(performance.now() - t0);
  const ok = results.filter((r) => r.status === 200).length;
  const shed = results.filter((r) => r.status === 503).length;
  $("predict-out").textContent =
    `${n} request(s) in ${ms} ms — ${ok} ok, ${shed} shed (503), ${n - ok - shed} other\n` +
    results.slice(0, 3).map((r) => `HTTP ${r.status} ${r.body.slice(0, 90)}`).join("\n");
}

async function slowAndPing() {
  const t0 = performance.now();
  const slow = request("/api/v1/predict", { method: "POST", body: "1,2,3" }, 30000);
  await new Promise((r) => setTimeout(r, 30));
  const t1 = performance.now();
  const health = await request("/healthz", {}, 5000);
  const ping = Math.round(performance.now() - t1);
  const slowRes = await slow;
  const slowMs = Math.round(performance.now() - t0);
  const responsive = ping < 150;
  const verdict = state.executor === "async"
    ? (responsive
        ? "→ executor=async: the handler ran on a worker; the engine stayed responsive"
        : "→ executor=async: health was slow (workers saturated?)")
    : (responsive
        ? "→ executor=sync: not blocked — expected only with :uring and one worker"
        : "→ executor=sync: the handler ran on the engine; health waited for it");
  $("predict-out").textContent =
    `slow handler: HTTP ${slowRes.status} in ${slowMs} ms (think ${THINK_MS} ms)\n` +
    `health during: HTTP ${health.status} in ${ping} ms\n` + verdict;
}

// Upload, routes, admin

async function upload(bytes) {
  const { status, body } = await request("/api/v1/upload", {
    method: "POST",
    body: "x".repeat(bytes),
  });
  $("upload-out").textContent =
    `HTTP ${status} · ${bytes} bytes${status === 413 ? " (per-route limit is 4 KB)" : ""}\n${body}`;
}

const ROUTES = [
  ["GET /api/v1/models", "GET", "/api/v1/models"],
  ["GET /api/v1/models/2", "GET", "/api/v1/models/2"],
  ["GET /api/v1/models/99 → 404", "GET", "/api/v1/models/99"],
  ["DELETE /api/v1/predict → 405", "DELETE", "/api/v1/predict"],
  ["GET /old → 302", "GET", "/old"],
  ["HEAD /api/v1/models/1", "HEAD", "/api/v1/models/1"],
  ["GET /api/v1/boom → 500", "GET", "/api/v1/boom"],
  ["GET /api/v1/echo?q=hi&n=2", "GET", "/api/v1/echo?q=hi&n=2"],
  ["GET /api/v1/files/a/b/c", "GET", "/api/v1/files/a/b/c"],
  ["GET /api/v1/audit", "GET", "/api/v1/audit"],
  ["GET /missing → 404", "GET", "/missing"],
];

function renderRoutes() {
  $("routes").innerHTML = ROUTES
    .map(([label, method, path], i) =>
      `<button class="ghost" data-i="${i}">${label}</button>`)
    .join("");
  for (const b of document.querySelectorAll("#routes button")) {
    b.onclick = async () => {
      const [, method, path] = ROUTES[Number(b.dataset.i)];
      const r = await request(path, { method });
      $("raw").textContent = `${method} ${path}\nHTTP ${r.status}\n\n${r.body.slice(0, 600)}`;
    };
  }
}

async function adminAction(path, opts) {
  const r = await admin(path, opts);
  $("admin-out").textContent = `HTTP ${r.status}\n${r.body.slice(0, 700)}`;
}

// Wiring

$("executor").onchange = () => {
  state.executor = $("executor").value;
  abortStream();
  refreshProbes();
  refreshMetrics();
  refreshPrometheus();
  refreshLog();
};
$("gen-sse").onclick = streamSSE;
$("gen-txt").onclick = streamTxt;
$("gen-abort").onclick = abortStream;
$("predict").onclick = () => predict(1);
$("predict-10").onclick = () => predict(10);
$("slow-ping").onclick = slowAndPing;
$("upload-ok").onclick = () => upload(100);
$("upload-big").onclick = () => upload(8000);
$("adm-stats").onclick = () => adminAction("/admin/stats");
$("adm-config").onclick = () => adminAction("/admin/config");
$("adm-log").onclick = () => adminAction("/admin/log/tail");
$("maint-on").onclick = () => adminAction("/admin/maintenance", { method: "POST", body: "on" })
  .then(refreshProbes);
$("maint-off").onclick = () => adminAction("/admin/maintenance", { method: "POST", body: "off" })
  .then(refreshProbes);
$("token").addEventListener("change", () => { refreshLog(); });

renderRoutes();
refreshProbes();
refreshMetrics();
refreshPrometheus();
refreshLog();
setInterval(() => { refreshProbes(); refreshMetrics(); }, 1000);
setInterval(refreshLog, 2000);
