// Ciro.jl ML dashboard — vanilla JS, no dependencies.

const $ = (id) => document.getElementById(id);
const fmt = (n) => Number(n).toLocaleString();

async function request(url, opts) {
  try {
    const res = await fetch(url, opts);
    return { status: res.status, body: await res.text() };
  } catch (err) {
    return { status: 0, body: `network error: ${err.message}` };
  }
}

async function refreshHealth() {
  const { status, body } = await request("/api/health");
  if (status !== 200) {
    $("health").textContent = "unreachable — retrying";
    return;
  }
  const h = JSON.parse(body);
  $("health").textContent = `ok · up ${h.uptime_s}s`;
}

async function refreshModels() {
  const { body } = await request("/api/v1/models");
  const { models } = JSON.parse(body);
  $("models").innerHTML = models
    .map((m) => `<li><b>${m.name}</b><span>#${m.id} · ${m.kind} · ${fmt(m.params)} params</span></li>`)
    .join("");
}

async function refreshMetrics() {
  const { status, body } = await request("/api/metrics");
  if (status !== 200) {
    $("metrics").innerHTML =
      `<div class="metrics-down"><span>server</span><b>${status === 503 ? "busy (503)" : "unreachable"}</b></div>`;
    return;
  }
  const m = JSON.parse(body);
  const cells = [
    ["requests", m.requests],
    ["responses", m.responses],
    ["2xx", m.status_2xx],
    ["4xx", m.status_4xx],
    ["5xx", m.status_5xx],
    ["exceptions", m.exceptions],
    ["bytes in", m.bytes_in],
    ["bytes out", m.bytes_out],
  ];
  $("metrics").innerHTML = cells
    .map(([k, v]) => `<div><span>${k}</span><b>${fmt(v)}</b></div>`)
    .join("");
}

async function predict() {
  const features = $("features").value;
  const t0 = performance.now();
  const { status, body } = await request("/api/v1/predict", { method: "POST", body: features });
  const ms = Math.round(performance.now() - t0);
  const note = status === 0 ? "request failed (server unreachable?)" :
               status === 503 ? "server busy — the worker pool is full (open streams?)" : "";
  $("result").textContent = `HTTP ${status} · client round-trip ${ms} ms${note ? " · " + note : ""}\n${body}`;
}

async function upload(bytes) {
  const { status, body } = await request("/api/v1/upload", {
    method: "POST",
    body: "x".repeat(bytes),
  });
  const note = status === 0 ? "request failed (connection reset by the 413 close?)" :
               status === 503 ? "server busy" : "";
  $("result").textContent = `HTTP ${status} · uploaded ${bytes} bytes${note ? " · " + note : ""}\n${body}`;
}

async function audit() {
  const { status, body } = await request("/api/v1/audit");
  $("result").textContent = `HTTP ${status}\n${body}`;
}

function connectEvents() {
  const events = $("events");
  const es = new EventSource("/api/v1/events");
  es.addEventListener("metrics", (ev) => {
    const d = JSON.parse(ev.data);
    if (events.querySelector(".muted")) events.innerHTML = "";
    const line = document.createElement("div");
    line.textContent = `t=${d.tick}  requests=${d.requests}  responses=${d.responses}  errors=${d.errors}`;
    events.prepend(line);
    while (events.childElementCount > 20) events.lastChild.remove();
  });
  es.onerror = () => {
    events.innerHTML =
      '<div class="muted">stream lost — reconnecting… (each open stream holds a server worker; ' +
      'if the pool is full, other requests wait or get 503)</div>';
  };
}

$("predict").onclick = predict;
$("upload-ok").onclick = () => upload(100);
$("upload-big").onclick = () => upload(8000);
$("audit").onclick = audit;

refreshHealth();
refreshModels();
refreshMetrics();
setInterval(() => {
  refreshHealth();
  refreshMetrics();
}, 1000);
connectEvents();
