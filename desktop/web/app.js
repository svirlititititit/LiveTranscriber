// Page logic of the desktop port of LiveTranscriber. It mirrors the iOS app: the sound is
// split into utterances by SpeechGate, every utterance gets a voiceprint and goes to the
// local recognizer (server.py), and the transcript is kept in the browser.

import { resample } from "./dsp.js";
import { SpeechGate } from "./gate.js";
import { extractVoiceprint, SpeakerReference } from "./voiceprint.js";

const RATE = 16000;
const MAX_SEGMENT_SECONDS = 50;
const TAIL_SECONDS = 0.35;
const DRAFT_SECONDS = 2;
const MAX_SEGMENTS = 500;
const LOG_CAPACITY = 300;
const STORAGE_KEY = "livetranscriber.v1";

const DEFAULT_SETTINGS = Object.freeze({
  micProcessing: "standard",
  deviceId: "",
  marginDb: 8,
  pauseSeconds: 0.8,
  fontSize: 21,
});

const SPEAKER_NAMES = { teacher: "Учитель", other: "Другой", unknown: "Кто говорил?" };
const MINIMUM_DB = -70;

const byId = (id) => document.getElementById(id);
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

const transcriptElement = byId("transcript");
const partialElement = byId("partial");
const hintElement = byId("hint");
const statusElement = byId("status");
const engineElement = byId("engine");
const listenButton = byId("listen-button");
const meterFill = byId("meter-fill");
const meterMark = byId("meter-mark");
const meterText = byId("meter-text");
const menuElement = byId("menu");
const logBox = byId("log-box");
const logElement = byId("log");

const state = {
  settings: { ...DEFAULT_SETTINGS },
  segments: [],
  log: [],
  /** "microphone", "file" or null. */
  source: null,
  /** The latest answer of /api/status. */
  engine: null,
  /** Shown in the status line until the next action, e.g. why the microphone did not start. */
  notice: null,
  /** True while the browser is asking for microphone access. */
  pendingMicRequest: false,
  reference: new SpeakerReference(),
};

let audio = null;            // AudioContext, at 16 kHz when the browser allows
let worklet = null;          // the sound input node: AudioWorklet, or the older kind as a fallback
let monitor = null;          // lets a recording be heard; the microphone stays muted
let microphone = null;
let mediaStreams = [];       // every stream the browser granted, so all can be stopped
let recording = null;
let gate = new SpeechGate();
let capturing = false;
let tail = [];               // the last moments of sound, kept as a lead-in for the next utterance
let tailSeconds = 0;
let current = null;          // the utterance being recorded
let nextId = 1;
let voiceWorker = null;
let voiceprintRequests = new Map();
let voiceprintRequestCount = 0;
let pollTimer = null;
let lastMeterPaint = 0;

// ---------- Saved state ----------

function load() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "null");
    if (saved) {
      state.settings = { ...DEFAULT_SETTINGS, ...(saved.settings || {}) };
      if (Array.isArray(saved.segments)) state.segments = saved.segments;
    }
  } catch (error) {
    addLog(`сохранённое не прочиталось: ${error.message}`);
  }
  nextId = state.segments.reduce((largest, segment) => Math.max(largest, segment.id), 0) + 1;
  rebuildReference();
}

function persist() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ settings: state.settings, segments: state.segments }));
  } catch (error) {
    addLog(`не удалось сохранить: ${error.message}`);
  }
}

function applySettings() {
  const settings = state.settings;
  gate.updateSettings({ marginDb: settings.marginDb, pauseSeconds: settings.pauseSeconds });
  document.documentElement.style.setProperty("--text-size", `${settings.fontSize}px`);

  byId("margin").value = settings.marginDb;
  byId("margin-output").textContent = settings.marginDb;
  byId("pause").value = settings.pauseSeconds;
  byId("pause-output").textContent = settings.pauseSeconds.toFixed(1).replace(".", ",");
  byId("font-size").value = settings.fontSize;
  byId("font-output").textContent = settings.fontSize;
  byId("processing").value = settings.micProcessing;
  byId("device").value = settings.deviceId;
}

function saveSettings(settings) {
  state.settings = { ...state.settings, ...settings };
  applySettings();
  persist();
}

// ---------- Listening ----------

async function ensureAudio() {
  // A half-initialized context (the module failed to load last time) is started over,
  // so a retry never connects anything to a missing node.
  if (audio && worklet) return audio;
  await teardownAudio();

  try {
    audio = new AudioContext({ sampleRate: RATE, latencyHint: "interactive" });
  } catch (error) {
    audio = new AudioContext({ latencyHint: "interactive" });
    addLog(`частота ${RATE} Гц не поддерживается, работаю на ${audio.sampleRate} Гц`);
  }

  let input = null;
  try {
    if (audio.audioWorklet) {
      await audio.audioWorklet.addModule("./capture-worklet.js");
      const node = new AudioWorkletNode(audio, "capture-processor",
        { numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1] });
      node.port.onmessage = (event) => onChunk(event.data);
      input = node;
    }
  } catch (error) {
    // A browser extension can block the module: fall back to the older sound path.
    addLog(`звуковой модуль страницы не загрузился (${error.message}), включаю запасной`);
    input = null;
  }

  if (!input) {
    if (typeof audio.createScriptProcessor !== "function") {
      await teardownAudio();
      throw new Error("браузер не даёт странице слушать звук. Обнови страницу (F5) или попробуй другой браузер — Chrome или Edge");
    }
    const node = audio.createScriptProcessor(4096, 1, 1);
    node.onaudioprocess = (event) => {
      // The buffer is reused by the browser: keep a copy.
      onChunk(Float32Array.from(event.inputBuffer.getChannelData(0)));
    };
    input = node;
  }

  monitor = audio.createGain();
  monitor.gain.value = 0;
  input.connect(monitor);
  monitor.connect(audio.destination);
  worklet = input;
  return audio;
}

async function teardownAudio() {
  if (microphone) {
    microphone.disconnect();
    microphone = null;
  }
  if (worklet) {
    try {
      worklet.disconnect();
    } catch (error) {
      // It may already be disconnected.
    }
    worklet = null;
  }
  if (monitor) {
    try {
      monitor.disconnect();
    } catch (error) {
      // Same.
    }
    monitor = null;
  }
  if (audio) {
    try {
      await audio.close();
    } catch (error) {
      // Same.
    }
    audio = null;
  }
}

/** Runs the promise, but gives up after `milliseconds` with a message of its own. */
async function withTimeout(promise, milliseconds, message) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(message)), milliseconds);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

function microphoneConstraints(processing, deviceId, askRate) {
  const constraints = {
    audio: {
      channelCount: { ideal: 1 },
      echoCancellation: processing,
      noiseSuppression: processing,
      autoGainControl: processing,
    },
  };
  if (deviceId) constraints.audio.deviceId = { exact: deviceId };
  if (askRate) constraints.audio.sampleRate = { ideal: RATE };
  return constraints;
}

async function requestMicrophone() {
  const processing = state.settings.micProcessing !== "raw";
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia(
      microphoneConstraints(processing, state.settings.deviceId, true));
  } catch (error) {
    switch (error.name) {
      case "NotAllowedError":
      case "SecurityError":
        throw new Error("доступ к микрофону запрещён. Разреши его значком камеры в адресной строке браузера и нажми ещё раз");
      case "NotFoundError":
      case "DevicesNotFoundError":
        throw new Error("микрофон не найден. Подключи его или открой запись для проверки");
      case "NotReadableError":
      case "TrackStartError":
        throw new Error("микрофон занят другой программой. Закрой её и попробуй снова");
      default:
        // The chosen microphone may be gone, or the browser may not know the sample rate
        // request: ask again without both.
        stream = await navigator.mediaDevices.getUserMedia(microphoneConstraints(processing, "", false));
    }
  }
  return stream;
}

async function startMicrophone() {
  listenButton.disabled = true;
  state.pendingMicRequest = true;
  renderStatus();
  try {
    const context = await ensureAudio();
    await releaseSources();
    const pending = requestMicrophone();
    // A stream the browser grants after we have already given up must not stay alive.
    pending.then((late) => mediaStreams.push(late)).catch(() => {});
    const stream = await withTimeout(pending, 20000,
      "браузер не ответил на запрос микрофона. Возможно, окно разрешения закрылось — нажми ещё раз и разреши доступ");
    await context.resume();
    if (!worklet) {
      throw new Error("звуковой модуль страницы не загрузился. Обнови страницу (F5) и попробуй ещё раз");
    }
    microphone = context.createMediaStreamSource(stream);
    microphone.connect(worklet);
    beginCapture("microphone");
    await refreshDevices();
  } catch (error) {
    await releaseSources();
    state.source = null;
    state.notice = `Микрофон не включился: ${error.message}.`;
    addLog(`микрофон не включился: ${error.message}`);
  } finally {
    state.pendingMicRequest = false;
    listenButton.disabled = false;
    renderStatus();
    renderListenButton();
  }
}

function beginCapture(source) {
  gate.reset();
  gate.updateSettings({ marginDb: state.settings.marginDb, pauseSeconds: state.settings.pauseSeconds });
  tail = [];
  tailSeconds = 0;
  current = null;
  capturing = true;
  state.source = source;
  state.notice = null;
  addLog(source === "microphone" ? "микрофон включён" : "запись пошла");
  renderStatus();
  renderListenButton();
}

function stopListening() {
  if (current) endUtterance();
  capturing = false;
  state.source = null;
  state.notice = null;
  releaseSources();
  renderPartial("");
  renderStatus();
  renderListenButton();
  updateMeter();
}

async function releaseSources() {
  if (recording) {
    recording.onended = null;
    try {
      recording.stop();
    } catch (error) {
      // It has already ended.
    }
    recording = null;
  }
  if (microphone) {
    microphone.disconnect();
    microphone = null;
  }
  for (const stream of mediaStreams) {
    stream.getTracks().forEach((track) => track.stop());
  }
  mediaStreams = [];
  if (monitor) monitor.gain.value = 0;
}

async function playFile(file) {
  try {
    await playRecording(await file.arrayBuffer(), file.name);
  } catch (error) {
    addLog(`запись «${file.name}» не открылась: ${error.message}`);
    renderStatus();
  }
}

/** Plays a recording through the same path as the microphone, at its real speed. */
async function playRecording(arrayBuffer, name) {
  const context = await ensureAudio();
  await releaseSources();
  await context.resume();
  const buffer = await context.decodeAudioData(arrayBuffer);
  const source = context.createBufferSource();
  source.buffer = buffer;
  source.connect(worklet);
  monitor.gain.value = byId("monitor").checked ? 1 : 0;
  recording = source;
  beginCapture("file");
  addLog(`запись «${name}»: ${buffer.duration.toFixed(1)} с`);
  source.onended = () => {
    if (state.source === "file") stopListening();
  };
  source.start();
}

async function playUrl(url, name = url.split("/").pop()) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`не удалось скачать ${url}: ${response.status}`);
  await playRecording(await response.arrayBuffer(), name);
}

// ---------- Splitting the sound into utterances ----------

function onChunk(chunk) {
  if (!capturing) return;
  if (audio.sampleRate !== RATE) chunk = resample(chunk, audio.sampleRate, RATE);
  if (chunk.length === 0) return;

  const events = [];
  if (current && current.seconds >= MAX_SEGMENT_SECONDS) {
    gate.forceEnd();
    events.push("speechEnded");
  }
  events.push(...gate.process(chunk, RATE));

  for (const event of events) {
    if (event === "speechStarted") {
      beginUtterance(true);
    } else if (event === "speechEnded") {
      endUtterance();
      // An utterance that grew too long is cut and the next one starts at once.
      if (gate.isSpeechActive) beginUtterance(false);
    }
  }

  if (current) {
    current.parts.push(chunk);
    current.seconds += chunk.length / RATE;
    maybeRequestDraft();
  }

  tail.push(chunk);
  tailSeconds += chunk.length / RATE;
  while (tailSeconds > TAIL_SECONDS && tail.length > 0) {
    const first = tail.shift();
    tailSeconds -= first.length / RATE;
  }

  updateMeter();
}

function beginUtterance(withLeadIn) {
  if (current) endUtterance();
  const parts = withLeadIn ? [...tail] : [];
  current = { id: nextId, startedAt: new Date(), parts, seconds: secondsOf(parts), draftedSeconds: 0, draftCount: 0 };
  nextId += 1;
  addLog(`реплика #${current.id} началась`);
}

function endUtterance() {
  if (!current) return;
  const utterance = current;
  current = null;
  renderPartial("");

  if (utterance.seconds < 0.6) {
    addLog(`реплика #${utterance.id}: слишком короткая, пропускаю`);
    return;
  }
  const samples = concat(utterance.parts);
  const floorDb = gate.noiseFloorDb;
  addLog(`реплика #${utterance.id} закончилась: ${utterance.seconds.toFixed(1)} с`);

  Promise.all([requestVoiceprint(samples), recognize(samples, false)])
    .then(([voiceprint, result]) => publish(utterance, result, voiceprint, floorDb))
    .catch((error) => addLog(`реплика #${utterance.id} не распознана: ${error.message}`));
}

/** While a person is still speaking, shows a draft now and then when recognition is fast. */
function maybeRequestDraft() {
  if (!current || !state.engine || !state.engine.draftCapable) return;
  const utterance = current;
  if (utterance.seconds < 1.2 || utterance.seconds - utterance.draftedSeconds < DRAFT_SECONDS) return;

  const draft = ++utterance.draftCount;
  utterance.draftedSeconds = utterance.seconds;
  recognize(concat(utterance.parts), true)
    .then((result) => {
      if (current === utterance && utterance.draftCount === draft) renderPartial(result.text);
    })
    .catch(() => {
      // A draft is a nicety: the final text is what matters.
    });
}

async function recognize(samples, isDraft) {
  const pcm = new Int16Array(samples.length);
  for (let index = 0; index < samples.length; index++) {
    pcm[index] = Math.max(-32768, Math.min(32767, Math.round(samples[index] * 32768)));
  }

  // The recognizer may still be loading: keep the utterance until it is ready.
  for (let attempt = 0; ; attempt++) {
    let response;
    try {
      response = await fetch(`/api/recognize${isDraft ? "?draft=1" : ""}`, {
        method: "POST",
        headers: { "Content-Type": "application/octet-stream" },
        body: pcm,
      });
    } catch (error) {
      throw new Error(`сервер недоступен: ${error.message}`);
    }
    const payload = await response.json().catch(() => ({}));
    if (response.ok) return payload;
    if (response.status === 503 && attempt < 120) {
      await delay(1000);
      continue;
    }
    throw new Error(payload.error || `ошибка ${response.status}`);
  }
}

function requestVoiceprint(samples) {
  if (!voiceWorker) return Promise.resolve(extractVoiceprint(samples, RATE));
  return new Promise((resolve, reject) => {
    const requestId = ++voiceprintRequestCount;
    voiceprintRequests.set(requestId, { resolve, reject });
    const copy = new Float32Array(samples);
    voiceWorker.postMessage({ requestId, samples: copy, sampleRate: RATE }, [copy.buffer]);
  });
}

function createVoiceWorker() {
  try {
    const worker = new Worker("./voiceprint-worker.js", { type: "module" });
    worker.onmessage = (event) => {
      const pending = voiceprintRequests.get(event.data.requestId);
      if (!pending) return;
      voiceprintRequests.delete(event.data.requestId);
      pending.resolve(event.data.voiceprint);
    };
    worker.onerror = (event) => {
      addLog(`отпечаток голоса считается в основном потоке: ${event.message}`);
      voiceWorker = null;
      worker.terminate();
      for (const pending of voiceprintRequests.values()) {
        pending.resolve(extractVoiceprint(new Float32Array(0), RATE));
      }
      voiceprintRequests.clear();
    };
    voiceWorker = worker;
  } catch (error) {
    addLog(`отпечаток голоса считается в основном потоке: ${error.message}`);
  }
}

function secondsOf(parts) {
  return parts.reduce((seconds, part) => seconds + part.length / RATE, 0);
}

function concat(parts) {
  const samples = new Float32Array(parts.reduce((length, part) => length + part.length, 0));
  let position = 0;
  for (const part of parts) {
    samples.set(part, position);
    position += part.length;
  }
  return samples;
}

// ---------- The transcript ----------

function publish(utterance, result, voiceprint, floorDb) {
  const text = (result.text || "").trim();
  if (!text) {
    addLog(`реплика #${utterance.id}: слов не найдено (${Math.round(result.ms)} мс)`);
    return;
  }
  const segment = {
    id: utterance.id,
    startedAt: utterance.startedAt.toISOString(),
    text,
    speaker: "unknown",
    isLabelManual: false,
    teacherSimilarity: null,
    otherSimilarity: null,
    voiceprint: voiceprint || null,
    levelAboveFloorDb: voiceprint ? voiceprint.levelDb - floorDb : null,
    seconds: utterance.seconds,
  };
  applyVerdict(segment);
  addLog(`реплика #${segment.id} распознана за ${Math.round(result.ms)} мс`);

  let index = state.segments.findIndex((other) => other.id > segment.id);
  if (index === -1) index = state.segments.length;
  state.segments.splice(index, 0, segment);
  if (state.segments.length > MAX_SEGMENTS) state.segments.splice(0, state.segments.length - MAX_SEGMENTS);

  const nearEnd = document.documentElement.scrollHeight - window.scrollY - window.innerHeight < 160;
  const row = createRow(segment);
  transcriptElement.insertBefore(row, transcriptElement.children[index] || null);
  removeEmptyMessage();
  renderHint();
  persist();
  if (nearEnd) row.scrollIntoView({ block: "end", behavior: "smooth" });
}

function findSegment(id) {
  return state.segments.find((segment) => segment.id === id);
}

function applyVerdict(segment) {
  const verdict = state.reference.verdict(segment.voiceprint && segment.voiceprint.vector);
  if (!verdict) {
    segment.speaker = "unknown";
    segment.teacherSimilarity = null;
    segment.otherSimilarity = null;
    return;
  }
  segment.speaker = verdict.speaker;
  segment.teacherSimilarity = round2(verdict.teacherSimilarity);
  segment.otherSimilarity = round2(verdict.otherSimilarity);
}

function setLabel(id, speaker) {
  const segment = findSegment(id);
  if (!segment) return;
  segment.speaker = speaker;
  segment.isLabelManual = speaker !== null;
  relabelFromExamples();
  persist();
}

/** Rebuilds the voice examples from the utterances the user labelled by hand. */
function rebuildReference() {
  const reference = new SpeakerReference();
  for (const segment of state.segments) {
    if (segment.isLabelManual && segment.voiceprint) {
      reference.add(segment.voiceprint.vector, segment.speaker);
    }
  }
  state.reference = reference;
}

function relabelFromExamples() {
  rebuildReference();
  for (const segment of state.segments) {
    if (!segment.isLabelManual) applyVerdict(segment);
    const row = transcriptElement.querySelector(`[data-id="${segment.id}"]`);
    if (row) paintRow(row, segment);
  }
  renderHint();
}

function clearTranscript() {
  state.segments = [];
  transcriptElement.replaceChildren();
  relabelFromExamples();
  nextId = 1;
  persist();
  renderHint();
}

function exportText() {
  const day = new Intl.DateTimeFormat("ru-RU", { dateStyle: "short", timeStyle: "short" }).format(new Date());
  const lines = [`LiveTranscriber, ${day}`, ""];
  for (const segment of state.segments) {
    const time = new Intl.DateTimeFormat("ru-RU", { timeStyle: "medium" }).format(new Date(segment.startedAt));
    const name = SPEAKER_NAMES[segment.speaker] + (segment.isLabelManual ? " (отмечено вручную)" : "");
    lines.push(`[${time}] ${name}: ${segment.text}`);
  }
  return lines.join("\n");
}

// ---------- Drawing ----------

function createRow(segment) {
  const row = document.createElement("li");
  row.className = "utterance";
  row.dataset.id = segment.id;
  row.tabIndex = 0;

  const who = document.createElement("div");
  who.className = "who";
  const name = document.createElement("span");
  name.className = "name";
  const rule = document.createElement("span");
  rule.className = "rule";
  const time = document.createElement("time");
  const scores = document.createElement("span");
  scores.className = "scores";
  who.append(name, rule, time, scores);

  const text = document.createElement("p");
  text.className = "text";
  row.append(who, text);

  const open = (x, y) => openMenu(x, y, Number(segment.id));
  row.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    open(event.clientX, event.clientY);
  });
  row.addEventListener("keydown", (event) => {
    if (event.key !== "Enter" && event.key !== "ContextMenu") return;
    event.preventDefault();
    const box = row.getBoundingClientRect();
    open(box.left + 24, box.top + 24);
  });

  paintRow(row, segment);
  return row;
}

function paintRow(row, segment) {
  row.dataset.speaker = segment.speaker;
  row.querySelector(".name").textContent = SPEAKER_NAMES[segment.speaker];
  row.querySelector("time").textContent = new Intl.DateTimeFormat("ru-RU", { timeStyle: "medium" })
    .format(new Date(segment.startedAt));
  const scores = row.querySelector(".scores");
  scores.textContent = segment.isLabelManual ? "отмечено вручную"
    : `${similarity(segment.teacherSimilarity)} к учителю, ${similarity(segment.otherSimilarity)} к остальным`;
  scores.hidden = segment.speaker === "unknown" && segment.teacherSimilarity === null;
  row.querySelector(".text").textContent = segment.text;
}

/** 0.95 is shown as "0,95" */
function similarity(value) {
  return value === null || value === undefined ? "—" : value.toFixed(2).replace(".", ",");
}

function removeEmptyMessage() {
  const empty = transcriptElement.querySelector(".empty");
  if (empty) empty.remove();
}

function renderTranscript() {
  transcriptElement.replaceChildren(...state.segments.map(createRow));
  if (state.segments.length === 0) {
    const empty = document.createElement("li");
    empty.className = "empty";
    empty.textContent = "Здесь появится речь с урока.";
    transcriptElement.append(empty);
  }
}

function renderHint() {
  const needsExamples = state.segments.length > 0
    && !(state.segments.some((segment) => segment.isLabelManual && segment.speaker === "teacher")
      && state.segments.some((segment) => segment.isLabelManual && segment.speaker === "other"));
  hintElement.hidden = !needsExamples;
  if (needsExamples) {
    hintElement.textContent = "Чтобы программа различала голоса, щёлкни по реплике правой кнопкой и отметь, кто говорил. "
      + "Нужно несколько реплик учителя и несколько реплик кого-то другого.";
  }
}

function renderPartial(text) {
  partialElement.textContent = text;
}

function renderListenButton() {
  const listeningToMicrophone = state.source === "microphone";
  listenButton.textContent = listeningToMicrophone ? "Остановить" : "Слушать микрофон";
  if (listeningToMicrophone) {
    listenButton.setAttribute("data-listening", "");
  } else {
    listenButton.removeAttribute("data-listening");
  }
}

function renderStatus() {
  statusElement.textContent = statusText();
}

function statusText() {
  if (state.pendingMicRequest) return "Запрашиваю доступ к микрофону…";
  if (state.notice) return state.notice;

  const engine = state.engine;
  let recognizer;
  if (!engine) {
    recognizer = "сервер не отвечает";
  } else if (engine.error) {
    recognizer = `распознавание не запустилось: ${engine.error}`;
  } else if (!engine.ready) {
    recognizer = "модель распознавания загружается";
  } else if (engine.engine === "cuda") {
    recognizer = `распознаёт видеокарта ${engine.device || ""}`.trim();
  } else {
    recognizer = "распознаёт процессор, реплики появляются с задержкой в несколько секунд";
  }

  if (state.source === "microphone") return `Слушаю микрофон, ${recognizer}.`;
  if (state.source === "file") return `Играет запись, ${recognizer}.`;
  return `Пауза, ${recognizer}.`;
}

function renderEngine() {
  const engine = state.engine;
  let text;
  let alert = false;
  if (!engine) {
    text = "Сервер не отвечает. Перезапусти приложение.";
    alert = true;
  } else if (engine.error) {
    text = `Распознавание не запущено: ${engine.error}.`;
    alert = true;
  } else if (!engine.ready) {
    text = "Модель загружается, это занимает до минуты…";
  } else if (engine.engine === "cuda") {
    text = `Модель ${engine.model}, считает видеокарта ${engine.device || "несколько"}.`;
  } else {
    text = `Модель ${engine.model}, считает процессор: реплика появляется через несколько секунд после паузы.`;
  }
  engineElement.textContent = text;
  engineElement.classList.toggle("is-alert", alert);
}

function updateMeter() {
  if (!capturing) {
    meterFill.style.width = "0%";
    meterFill.classList.remove("is-speech");
    meterText.textContent = "Уровень звука появится, когда начнётся прослушивание.";
    return;
  }

  const now = performance.now();
  if (now - lastMeterPaint < 100) return;
  lastMeterPaint = now;

  const fraction = (decibels) => Math.max(0, Math.min(1, (decibels - MINIMUM_DB) / -MINIMUM_DB));
  const shown = (decibels) => Math.max(-100, Math.round(decibels));
  meterFill.style.width = `${fraction(gate.levelDb) * 100}%`;
  meterFill.classList.toggle("is-speech", gate.isSpeechActive);
  meterMark.style.left = `${fraction(gate.thresholdDb) * 100}%`;
  meterText.textContent = `звук ${shown(gate.levelDb)} дБ, шум ${shown(gate.noiseFloorDb)} дБ, порог ${shown(gate.thresholdDb)} дБ, `
    + `${gate.isSpeechActive ? "речь" : "тишина"}`;
}

function addLog(message) {
  const time = new Intl.DateTimeFormat("ru-RU", { timeStyle: "medium" }).format(new Date());
  state.log.push(`${time}  ${message}`);
  if (state.log.length > LOG_CAPACITY) state.log.splice(0, state.log.length - LOG_CAPACITY);
  renderLog();
}

function renderLog() {
  if (logBox.hidden) return;
  logElement.textContent = state.log.slice(-150).join("\n");
  logElement.scrollTop = logElement.scrollHeight;
}

async function refreshDevices() {
  if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return;
  const devices = (await navigator.mediaDevices.enumerateDevices()).filter((device) => device.kind === "audioinput");
  const select = byId("device");
  const previous = select.value;

  select.replaceChildren();
  const automatic = document.createElement("option");
  automatic.value = "";
  automatic.textContent = "Как в системе";
  select.append(automatic);
  for (const device of devices) {
    const option = document.createElement("option");
    option.value = device.deviceId;
    option.textContent = device.label || `Микрофон ${devices.indexOf(device) + 1}`;
    select.append(option);
  }
  select.value = devices.some((device) => device.deviceId === (previous || state.settings.deviceId))
    ? (previous || state.settings.deviceId)
    : "";
}

async function pollEngine() {
  clearTimeout(pollTimer);
  try {
    const response = await fetch("/api/status", { cache: "no-store" });
    state.engine = await response.json();
  } catch (error) {
    state.engine = null;
  }
  renderStatus();
  renderEngine();
  pollTimer = setTimeout(pollEngine, state.engine && state.engine.ready ? 10000 : 1000);
}

// ---------- The menu that marks who spoke ----------

function openMenu(x, y, id) {
  const segment = findSegment(id);
  if (!segment) return;

  const items = [["Это учитель", "teacher"], ["Это не учитель", "other"]];
  if (segment.isLabelManual) items.push(["Убрать отметку", null]);
  menuElement.replaceChildren();

  for (const [label, speaker] of items) {
    const button = document.createElement("button");
    button.type = "button";
    button.setAttribute("role", "menuitem");
    button.textContent = label;
    button.addEventListener("click", () => {
      closeMenu();
      setLabel(id, speaker);
    });
    menuElement.append(button);
  }
  const copy = document.createElement("button");
  copy.type = "button";
  copy.setAttribute("role", "menuitem");
  copy.textContent = "Скопировать текст";
  copy.addEventListener("click", async () => {
    closeMenu();
    try {
      await navigator.clipboard.writeText(segment.text);
    } catch (error) {
      addLog(`текст не скопировался: ${error.message}`);
    }
  });
  menuElement.append(copy);

  menuElement.hidden = false;
  const box = menuElement.getBoundingClientRect();
  menuElement.style.left = `${Math.min(x, window.innerWidth - box.width - 8)}px`;
  menuElement.style.top = `${Math.min(y, window.innerHeight - box.height - 8)}px`;
  menuElement.querySelector("button").focus();
}

function closeMenu() {
  menuElement.hidden = true;
}

// ---------- Wiring ----------

function saveFile(name, text) {
  const url = URL.createObjectURL(new Blob([text], { type: "text/plain;charset=utf-8" }));
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function round2(value) {
  return value === null || value === undefined ? null : Math.round(value * 100) / 100;
}

function wire() {
  listenButton.addEventListener("click", () => {
    if (state.source === "microphone") {
      stopListening();
    } else {
      startMicrophone();
    }
  });

  byId("file-button").addEventListener("click", () => byId("file-input").click());
  byId("file-input").addEventListener("change", (event) => {
    const file = event.target.files[0];
    event.target.value = "";
    if (file) playFile(file);
  });
  byId("monitor").addEventListener("change", () => {
    if (state.source === "file") monitor.gain.value = byId("monitor").checked ? 1 : 0;
  });

  document.body.addEventListener("dragover", (event) => event.preventDefault());
  document.body.addEventListener("drop", (event) => {
    event.preventDefault();
    const file = event.dataTransfer.files[0];
    if (file) playFile(file);
  });

  byId("margin").addEventListener("input", (event) => saveSettings({ marginDb: Number(event.target.value) }));
  byId("pause").addEventListener("input", (event) => saveSettings({ pauseSeconds: Number(event.target.value) }));
  byId("font-size").addEventListener("input", (event) => saveSettings({ fontSize: Number(event.target.value) }));
  byId("processing").addEventListener("change", (event) => {
    saveSettings({ micProcessing: event.target.value });
    if (state.source === "microphone") startMicrophone();
  });
  byId("device").addEventListener("change", (event) => {
    saveSettings({ deviceId: event.target.value });
    if (state.source === "microphone") startMicrophone();
  });

  byId("export-button").addEventListener("click", () => {
    const stamp = new Date().toISOString().slice(0, 16).replace("T", "-").replace(":", "");
    saveFile(`расшифровка-${stamp}.txt`, exportText());
  });
  byId("clear-button").addEventListener("click", () => {
    if (state.segments.length === 0 || window.confirm("Удалить всю расшифровку?")) clearTranscript();
  });
  byId("log-button").addEventListener("click", () => {
    logBox.hidden = !logBox.hidden;
    renderLog();
  });
  byId("copy-log-button").addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(state.log.join("\n"));
    } catch (error) {
      addLog(`журнал не скопировался: ${error.message}`);
    }
  });

  document.addEventListener("pointerdown", (event) => {
    if (!menuElement.hidden && !menuElement.contains(event.target)) closeMenu();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape") closeMenu();
  });
  window.addEventListener("resize", closeMenu);
}

async function main() {
  load();
  createVoiceWorker();
  applySettings();
  renderTranscript();
  renderHint();
  renderListenButton();
  renderStatus();
  updateMeter();
  wire();
  if (navigator.mediaDevices) {
    navigator.mediaDevices.addEventListener?.("devicechange", refreshDevices);
  }
  await pollEngine();
}

// For checking the app from outside and from the browser console.
window.livetranscriber = { playUrl, playRecording, startMicrophone, stopListening, state, gate };

main();
