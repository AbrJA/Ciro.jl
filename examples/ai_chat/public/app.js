// Ciro.jl AI chat — vanilla JS, no dependencies.

const $ = (id) => document.getElementById(id);
const esc = (s) =>
  String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

const state = {
  room: 1,
  name: localStorage.getItem("ciro-chat-name") || "you",
  es: null,
};

async function request(url, opts = {}) {
  try {
    const res = await fetch(url, opts);
    return { status: res.status, body: await res.text() };
  } catch (err) {
    return { status: 0, body: String(err) };
  }
}

function setStream(text, warn = false) {
  const el = $("stream");
  el.textContent = text;
  el.classList.toggle("warn", warn);
}

async function loadRooms() {
  const { body } = await request("/api/v1/rooms");
  const { rooms } = JSON.parse(body);
  $("rooms").innerHTML = rooms
    .map((r) => `<li><button data-id="${r.id}" class="${r.id === state.room ? "active" : ""}">
        <span>${esc(r.name)}</span><small>${r.messages} msg · ${r.subscribers} live</small></button></li>`)
    .join("");
  for (const b of document.querySelectorAll("#rooms button")) {
    b.onclick = () => selectRoom(Number(b.dataset.id));
  }
  const current = rooms.find((r) => r.id === state.room);
  if (current) $("online").textContent = `${current.subscribers} online`;
}

function addMessage(m) {
  const div = document.createElement("div");
  div.className = `msg ${m.kind}`;
  div.innerHTML =
    `<span class="meta">${esc(m.author)} · ${new Date(m.at * 1000).toLocaleTimeString()}</span>` +
    esc(m.text);
  $("messages").appendChild(div);
  $("messages").scrollTop = $("messages").scrollHeight;
}

async function loadHistory() {
  const { body } = await request(`/api/v1/rooms/${state.room}/messages`);
  const { messages } = JSON.parse(body);
  $("messages").innerHTML = "";
  messages.forEach(addMessage);
  $("transcript").href = `/api/v1/rooms/${state.room}/transcript`;
}

function connectEvents() {
  if (state.es) state.es.close();
  const es = new EventSource(`/api/v1/rooms/${state.room}/events`);
  state.es = es;
  es.onopen = () => setStream("live");
  es.addEventListener("message", (ev) => {
    addMessage(JSON.parse(ev.data));
    $("typing").textContent = "";
  });
  es.addEventListener("typing", (ev) => {
    const t = JSON.parse(ev.data);
    $("typing").textContent = `${t.author} is typing…`;
    setTimeout(() => ($("typing").textContent = ""), 3000);
  });
  es.addEventListener("presence", (ev) => {
    $("online").textContent = `${JSON.parse(ev.data).users} online`;
  });
  es.onerror = () => setStream("reconnecting…", true);
}

async function selectRoom(id) {
  state.room = id;
  await loadRooms();
  await loadHistory();
  connectEvents();
}

async function send(text) {
  if (!text.trim()) return;
  $("text").value = "";
  const { status, body } = await request(
    `/api/v1/rooms/${state.room}/messages?as=${encodeURIComponent(state.name)}`,
    { method: "POST", body: text });
  if (status !== 200) {
    $("note").textContent = `send failed: HTTP ${status} ${body.slice(0, 80)}`;
  }
}

async function importBytes(bytes) {
  const payload = "line\n".repeat(Math.max(1, Math.floor(bytes / 5)));
  const { status, body } = await request(`/api/v1/rooms/${state.room}/import`,
    { method: "POST", body: payload });
  $("note").textContent = `import (${payload.length} B): HTTP ${status} ${body.slice(0, 80)}`;
}

async function refreshMetrics() {
  const { status, body } = await request("/api/metrics");
  if (status !== 200) {
    $("metrics").textContent = "metrics unreachable";
    return;
  }
  const m = JSON.parse(body);
  $("metrics").textContent =
    `${m.requests} req · ${m.status_2xx} 2xx · ${m.status_4xx} 4xx · ${m.status_5xx} 5xx`;
}

$("composer").onsubmit = (e) => {
  e.preventDefault();
  send($("text").value);
};
$("name").value = state.name;
$("name").onchange = () => {
  state.name = $("name").value.trim() || "anon";
  localStorage.setItem("ciro-chat-name", state.name);
};
$("import-ok").onclick = () => importBytes(100);
$("import-big").onclick = () => importBytes(9000);

(async function main() {
  await loadRooms();
  await loadHistory();
  connectEvents();
  refreshMetrics();
  setInterval(() => {
    loadRooms();
    refreshMetrics();
  }, 2000);
})();
