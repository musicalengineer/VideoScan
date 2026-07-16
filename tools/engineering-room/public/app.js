const state = {
  topics: [], messages: [], activeTopicId: null,
  agents: { codex: { connection: "connecting", busy: false }, claude: { connection: "connecting", busy: false } },
  drafts: {},
};
const $ = selector => document.querySelector(selector);
const elements = {
  topics: $("#topics"), timeline: $("#timeline"), currentTopic: $("#currentTopic"), welcome: $("#welcome"),
  composer: $("#composer"), message: $("#message"), target: $("#target"), send: $("#send"), stop: $("#stop"),
  typing: $("#typing"), typingLabel: $("#typingLabel"), status: $("#roomStatus"), pulse: $("#statusPulse"),
  codex: $("#codexParticipant"), claude: $("#claudeParticipant"), toast: $("#toast"),
  speak: $("#speakReplies"),
};
const speechAvailable = "speechSynthesis" in window && "SpeechSynthesisUtterance" in window;
let speakReplies = speechAvailable && readPreference("engineering-room-speak") === "true";
updateSpeechButton();

boot().catch(error => showError(error.message));

async function boot() {
  const data = await api("/api/bootstrap");
  state.topics = data.topics;
  state.messages = data.messages;
  state.activeTopicId = state.topics.find(topic => topic.status === "active")?.id ?? state.topics[0]?.id ?? null;
  setAgents(data.agents ?? { codex: data.agent });
  render();
  const events = new EventSource("/api/events");
  events.addEventListener("room", event => receive(JSON.parse(event.data)));
  events.onerror = () => setAgents({ codex: { ...state.agents.codex, connection: "disconnected" }, claude: { ...state.agents.claude, connection: "disconnected" } });
}

function receive(event) {
  const { type, data } = event;
  if (type === "snapshot") {
    state.topics = data.topics; state.messages = data.messages; setAgents(data.agents ?? { codex: data.agent }); render(); return;
  }
  if (type === "topic.created") { upsert(state.topics, data); if (!state.activeTopicId) state.activeTopicId = data.id; render(); }
  if (type === "topic.updated") { upsert(state.topics, data); render(); }
  if (type === "message.created") {
    const isNew = !state.messages.some(message => message.id === data.id);
    upsert(state.messages, data);
    renderMessages();
    if (isNew && ["codex", "claude"].includes(data.author) && speakReplies) speak(`${displayName(data.author)} says. ${data.body}`);
  }
  if (type === "turn.started") {
    state.drafts[data.provider ?? "codex"] = { topicId: data.topicId, text: "" };
    setBusy(data.provider ?? "codex", true);
  }
  if (type === "agent.message.delta") {
    const draft = state.drafts[data.provider ?? "codex"];
    if (draft) draft.text += data.text;
    renderMessages();
  }
  if (type === "turn.completed" || type === "turn.interrupted") {
    delete state.drafts[data.provider ?? "codex"];
    setBusy(data.provider ?? "codex", false); renderMessages();
  }
  if (type === "agent.connection" || type === "codex.connection") {
    const provider = data.provider ?? "codex";
    setAgents({ [provider]: { ...state.agents[provider], connection: data.state } });
  }
  if (type === "room.error") { if (data.provider) setBusy(data.provider, false); showError(data.message); }
}

function render() { renderTopics(); renderMessages(); }

function renderTopics() {
  elements.topics.replaceChildren();
  for (const topic of [...state.topics].sort((a, b) => a.position - b.position)) {
    const button = document.createElement("button");
    button.className = `topic ${topic.id === state.activeTopicId ? "active" : ""} ${topic.status}`;
    button.type = "button";
    const dot = document.createElement("span"); dot.className = "dot";
    const title = document.createElement("span"); title.textContent = topic.title;
    const count = document.createElement("small"); count.textContent = String(state.messages.filter(message => message.topicId === topic.id).length);
    button.append(dot, title, count);
    button.addEventListener("click", () => { state.activeTopicId = topic.id; render(); });
    elements.topics.append(button);
  }
  const current = state.topics.find(topic => topic.id === state.activeTopicId);
  elements.currentTopic.textContent = current?.title ?? "Room notes";
  $("#topicMenu").textContent = current?.status === "parked" ? "Reactivate topic" : "Park topic";
}

function renderMessages() {
  const rows = state.messages.filter(message => message.topicId === null || message.topicId === state.activeTopicId);
  elements.timeline.replaceChildren();
  const visibleDrafts = Object.entries(state.drafts).filter(([, draft]) => draft.topicId === state.activeTopicId && draft.text);
  if (rows.length === 0 && visibleDrafts.length === 0) elements.timeline.append(elements.welcome);
  for (const message of rows) elements.timeline.append(messageNode(message));
  for (const [provider, draft] of visibleDrafts) elements.timeline.append(messageNode({ id: `draft-${provider}`, author: provider, body: draft.text, createdAt: new Date().toISOString() }));
  requestAnimationFrame(() => { elements.timeline.scrollTop = elements.timeline.scrollHeight; });
}

function messageNode(message) {
  const row = document.createElement("article"); row.className = `message-row ${message.author}`; row.dataset.id = message.id;
  const avatar = document.createElement("div"); avatar.className = "avatar"; avatar.textContent = ({ rick: "R", codex: "C", claude: "A", system: "·" })[message.author] ?? "·";
  const card = document.createElement("div"); card.className = "message-card";
  const meta = document.createElement("div"); meta.className = "message-meta";
  const author = document.createElement("strong"); author.textContent = displayName(message.author);
  const time = document.createElement("time"); time.dateTime = message.createdAt; time.textContent = new Intl.DateTimeFormat([], { hour: "numeric", minute: "2-digit" }).format(new Date(message.createdAt));
  const body = document.createElement("div"); body.className = "message-body"; body.textContent = message.body;
  meta.append(author, time); card.append(meta, body); row.append(avatar, card); return row;
}

function setAgents(patch = {}) {
  for (const [provider, status] of Object.entries(patch)) state.agents[provider] = { ...state.agents[provider], ...status };
  elements.codex.classList.toggle("present", state.agents.codex.connection === "connected");
  elements.claude.classList.toggle("present", ["connected", "available"].includes(state.agents.claude.connection));
  updateRoomStatus();
}

function setBusy(provider, busy) {
  state.agents[provider] = { ...state.agents[provider], busy };
  updateRoomStatus();
}

function updateRoomStatus() {
  const busy = Object.entries(state.agents).filter(([, status]) => status.busy).map(([provider]) => displayName(provider));
  const online = Object.values(state.agents).filter(status => ["connected", "available"].includes(status.connection)).length;
  const unverified = Object.values(state.agents).filter(status => status.connection === "available").length;
  elements.typing.hidden = busy.length === 0;
  elements.stop.hidden = busy.length === 0;
  elements.typingLabel.textContent = busy.length ? `${busy.join(" and ")} ${busy.length === 1 ? "is" : "are"} thinking` : "";
  elements.status.textContent = busy.length ? `${busy.join(" and ")} in conversation` : unverified ? "Room ready · Claude login checks on first message" : online === 2 ? "Room is ready" : `${online}/2 agents available`;
  elements.pulse.classList.toggle("connected", online === 2 && unverified === 0);
  elements.send.disabled = targetBusy();
}

function targetBusy() {
  const target = elements.target.value;
  if (target === "both") return state.agents.codex.busy || state.agents.claude.busy;
  return Boolean(state.agents[target]?.busy);
}

elements.composer.addEventListener("submit", async event => {
  event.preventDefault();
  const text = elements.message.value.trim();
  if (!text) return;
  elements.send.disabled = true;
  try {
    await api("/api/messages", { method: "POST", body: { topicId: state.activeTopicId, target: elements.target.value, text } });
    elements.message.value = "";
  } catch (error) { showError(error.message); }
  finally { elements.send.disabled = targetBusy(); }
});

elements.message.addEventListener("keydown", event => {
  if (event.key === "Enter" && event.metaKey) { event.preventDefault(); elements.composer.requestSubmit(); }
});
elements.target.addEventListener("change", updateRoomStatus);
elements.stop.addEventListener("click", () => api("/api/turns/current/interrupt", { method: "POST", body: {} }).catch(error => showError(error.message)));
elements.speak.addEventListener("click", () => {
  if (!speechAvailable) return;
  speakReplies = !speakReplies;
  writePreference("engineering-room-speak", String(speakReplies));
  if (!speakReplies) window.speechSynthesis.cancel();
  updateSpeechButton();
});
$("#newTopic").addEventListener("click", async () => {
  const title = window.prompt("New topic name:");
  if (!title?.trim()) return;
  try { const topic = await api("/api/topics", { method: "POST", body: { title } }); state.activeTopicId = topic.id; render(); }
  catch (error) { showError(error.message); }
});
$("#topicMenu").addEventListener("click", async () => {
  const topic = state.topics.find(item => item.id === state.activeTopicId); if (!topic) return;
  try { await api(`/api/topics/${topic.id}`, { method: "PATCH", body: { status: topic.status === "parked" ? "active" : "parked" } }); }
  catch (error) { showError(error.message); }
});

async function api(url, options = {}) {
  const init = { method: options.method ?? "GET", headers: {} };
  if (options.body !== undefined) { init.headers["Content-Type"] = "application/json"; init.body = JSON.stringify(options.body); }
  const response = await fetch(url, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(body.error ?? `Request failed (${response.status}).`);
  return body;
}

function upsert(list, value) { const index = list.findIndex(item => item.id === value.id); if (index === -1) list.push(value); else list[index] = value; }
function displayName(author) { return ({ rick: "Rick", codex: "Codex", claude: "Claude", system: "Room" })[author] ?? author; }
function updateSpeechButton() {
  elements.speak.disabled = !speechAvailable;
  elements.speak.setAttribute("aria-pressed", String(speakReplies));
  elements.speak.textContent = speechAvailable ? `Read replies aloud: ${speakReplies ? "on" : "off"}` : "Spoken replies unavailable";
}
function speak(text) {
  window.speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.rate = 1;
  window.speechSynthesis.speak(utterance);
}
function readPreference(key) { try { return localStorage.getItem(key); } catch { return null; } }
function writePreference(key, value) { try { localStorage.setItem(key, value); } catch { /* Current-tab behavior still works. */ } }
let toastTimer;
function showError(message) { clearTimeout(toastTimer); elements.toast.textContent = message; elements.toast.hidden = false; toastTimer = setTimeout(() => { elements.toast.hidden = true; }, 7000); }
