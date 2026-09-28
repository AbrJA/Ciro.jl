// Ciro.jl ops console — vanilla JS, no dependencies.

const $ = (id) => document.getElementById(id);
const fmt = (n) => Number(n).toLocaleString();
const token = () => $("token").value.trim();

async function request(url, opts = {}) {
  try {
    const res = await fetch(url, opts);
    return { status: res.status, body: await res.text() };
  } catch (err) {
    return { status: 0, body: `network error: ${err.message}` };
  }
}

const admin = (url, opts = {}) =>
  request(url, { ...opts, headers: { "X-Admin-Token": token(), ...(opts.headers ?? {}) } });

async function refreshProbes() {
  const h = await request("/healthz");
  $("health").textContent = h.status === 200 ? "live" : "down";

  const r = await request("/readyz");
  const ready = $("ready");
  if (r.status === 200) {
    ready.textContent = "ready";
    ready.classList.remove("warn");
  } else if (r.status === 503) {
    ready.textContent = "maintenance (503)";
    ready.classList.add("warn");
  } else {
    ready.textContent = "unknown";
    ready.classList.add("warn");
  }
}

async function refreshMetrics() {
  const { status, body } = await request("/api/metrics");
  if (status !== 200) {
    $("metrics").innerHTML =
      `<div class="metrics-down"><span>server</span><b>${status === 503 ? "busy" : "unreachable"}</b></div>`;
    return;
  }
  const m = JSON.parse(body);
  const cells = [
    ["requests", m.requests], ["responses", m.responses],
    ["2xx", m.status_2xx], ["4xx", m.status_4xx], ["5xx", m.status_5xx],
    ["exceptions", m.exceptions], ["bytes in", m.bytes_in], ["bytes out", m.bytes_out],
  ];
  $("metrics").innerHTML = cells
    .map(([k, v]) => `<div><span>${k}</span><b>${fmt(v)}</b></div>`)
    .join("");
}

async function refreshModels() {
  const { body } = await request("/api/v1/models");
  const { models } = JSON.parse(body);
  $("models").innerHTML = models
    .map((m) => `<li><b>${m.name}</b><span>#${m.id} · ${m.kind} · ${fmt(m.params)} params</span></li>`)
    .join("");
}

async function refreshConfig() {
  const { status, body } = await admin("/admin/config");
  if (status !== 200) {
    $("config").innerHTML = `<span class="muted">config needs the admin token (${status})</span>`;
    return;
  }
  const c = JSON.parse(body);
  $("config").innerHTML =
    `<span class="muted">${c.service} v${c.version}</span>` +
    `<code>backend=${c.backend} workers=${c.nworkers} max_body=${fmt(c.max_body_size)} ` +
    `max_conns=${fmt(c.max_connections)}</code>`;
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

async function upload(bytes) {
  const { status, body } = await request("/api/v1/upload", {
    method: "POST",
    body: "x".repeat(bytes),
  });
  const note = status === 0 ? "connection failed" :
               status === 413 ? "per-route limit is 4 KB" : "";
  $("result").textContent = `HTTP ${status} · uploaded ${bytes} bytes${note ? " · " + note : ""}\n${body}`;
}

async function maintenance(state) {
  const { status, body } = await admin("/admin/maintenance", { method: "POST", body: state });
  $("result").textContent = `HTTP ${status} · maintenance ${state}\n${body}`;
  refreshProbes();
}

$("upload-ok").onclick = () => upload(100);
$("upload-big").onclick = () => upload(8000);
$("maint-on").onclick = () => maintenance("on");
$("maint-off").onclick = () => maintenance("off");
$("token").addEventListener("change", () => {
  refreshConfig();
  refreshLog();
});

refreshProbes();
refreshMetrics();
refreshModels();
refreshConfig();
refreshPrometheus();
refreshLog();
setInterval(() => {
  refreshProbes();
  refreshMetrics();
}, 1000);
setInterval(refreshLog, 2000);
