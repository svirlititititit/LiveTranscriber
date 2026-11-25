// Tests for gate.js, ported from Tests/LessonCoreTests/SpeechGateTests.swift.
import assert from "node:assert/strict";
import test from "node:test";
import { SpeechGate } from "../web/gate.js";

const CHUNK = 512;       // 32 ms at 16 kHz
const RATE = 16000;

/** Deterministic pseudo-random numbers in [0, 1). */
function random(seed) {
  return { next: () => (((seed.value = (Math.imul(seed.value, 1664525) + 1013904223) >>> 0) % 100000) / 100000) };
}

/** White noise of the given peak amplitude. */
function noise(seed, amplitude) {
  const source = random(seed);
  return Float32Array.from({ length: CHUNK }, () => amplitude * (source.next() * 2 - 1));
}

/** Quiet white noise, about -65 dBFS. */
const quiet = (seed) => noise(seed, 0.001);

/** Loud white noise, about -5 dBFS. */
const loudNoise = (seed) => noise(seed, 1);

/** Speech-like sound: 0.2 s "syllables" at about -23 dBFS separated by 0.2 s at -37 dBFS. */
function speech(start) {
  const chunk = new Float32Array(CHUNK);
  for (let index = 0; index < CHUNK; index++) {
    const time = (start + index) / RATE;
    const amplitude = Math.sin(2 * Math.PI * 2.5 * time) > 0 ? 0.1 : 0.02;
    chunk[index] = amplitude * Math.sin(2 * Math.PI * 200 * time);
  }
  return chunk;
}

function feed(gate, chunks, events, startAt = 0) {
  for (let offset = 0; offset < chunks; offset++) {
    events.push(...gate.process(speech(startAt + offset * CHUNK), RATE));
  }
}

test("quiet never starts an utterance", () => {
  const seed = { value: 7 };
  const gate = new SpeechGate();
  const events = [];

  for (let index = 0; index < 200; index++) {
    events.push(...gate.process(quiet(seed), RATE));
  }

  assert.deepEqual(events, []);
  assert.ok(gate.levelDb < -55);
});

test("starts and ends an utterance", () => {
  const seed = { value: 7 };
  const gate = new SpeechGate();
  const events = [];

  for (let index = 0; index < 20; index++) events.push(...gate.process(quiet(seed), RATE));
  feed(gate, 20, events);
  assert.deepEqual(events, ["speechStarted"]);
  assert.equal(gate.isSpeechActive, true);

  for (let index = 0; index < 60; index++) events.push(...gate.process(quiet(seed), RATE));
  assert.deepEqual(events, ["speechStarted", "speechEnded"]);
  assert.equal(gate.isSpeechActive, false);
});

test("a click shorter than the hold time is ignored", () => {
  const seed = { value: 7 };
  const gate = new SpeechGate();
  const events = [];

  for (let index = 0; index < 200; index++) events.push(...gate.process(quiet(seed), RATE));
  events.push(...gate.process(loudNoise(seed), RATE));
  for (let index = 0; index < 100; index++) events.push(...gate.process(quiet(seed), RATE));

  assert.deepEqual(events, []);
});

test("long speech is not cut short", () => {
  const gate = new SpeechGate();
  const events = [];

  // 40 seconds of continuous speech with short dips between "syllables".
  feed(gate, 1250, events);

  assert.deepEqual(events, ["speechStarted"]);
  assert.equal(gate.isSpeechActive, true);
});

test("steady noise is not speech forever", () => {
  const seed = { value: 7 };
  const gate = new SpeechGate();
  const events = [];

  // A minute and a half of loud, steady noise.
  for (let index = 0; index < 2813; index++) {
    events.push(...gate.process(loudNoise(seed), RATE));
  }

  assert.deepEqual(events, ["speechStarted", "speechEnded"]);
  assert.equal(gate.isSpeechActive, false);
  assert.ok(gate.noiseFloorDb > -12);
});

test("a longer pause setting delays the end", () => {
  const seed = { value: 7 };
  const gate = new SpeechGate({ pauseSeconds: 2.0 });
  const events = [];

  for (let index = 0; index < 20; index++) events.push(...gate.process(quiet(seed), RATE));
  feed(gate, 20, events);
  for (let index = 0; index < 40; index++) events.push(...gate.process(quiet(seed), RATE));
  assert.deepEqual(events, ["speechStarted"]);
  for (let index = 0; index < 60; index++) events.push(...gate.process(quiet(seed), RATE));
  assert.deepEqual(events, ["speechStarted", "speechEnded"]);
});

test("forceEnd keeps the gate in the speech state", () => {
  const gate = new SpeechGate();
  const events = [];

  feed(gate, 20, events);
  gate.forceEnd();

  assert.equal(gate.isSpeechActive, true);
  feed(gate, 5, events, 20 * CHUNK);
  assert.deepEqual(events, ["speechStarted"]);
});

test("settings round-trip through JSON", () => {
  const original = { marginDb: 8, minimumLevelDb: -55, startHoldSeconds: 0.12, pauseSeconds: 0.8 };
  const gate = new SpeechGate(JSON.parse(JSON.stringify(original)));

  assert.deepEqual(gate.settings, original);
});

test("reset returns to the initial state", () => {
  const gate = new SpeechGate();
  const events = [];
  feed(gate, 20, events);

  gate.reset();

  assert.equal(gate.isSpeechActive, false);
  assert.equal(gate.levelDb, -100);
  assert.equal(gate.noiseFloorDb, -60);
});
