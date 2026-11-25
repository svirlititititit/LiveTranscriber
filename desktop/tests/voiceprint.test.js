// Tests for voiceprint.js, ported from Tests/LessonCoreTests/VoiceprintTests.swift.
import assert from "node:assert/strict";
import test from "node:test";
import { BAND_COUNT, SpeakerReference, cosineSimilarity, extractVoiceprint } from "../web/voiceprint.js";

const RATE = 16000;

/** A synthetic "voice": a 100 Hz buzz filtered to keep only the given harmonics. */
function voice(seconds, harmonics, gain, seed) {
  const samples = new Float32Array(Math.round(seconds * RATE));
  for (let index = 0; index < samples.length; index++) {
    const time = index / RATE;
    let value = 0;
    for (let harmonic = harmonics[0]; harmonic <= harmonics[1]; harmonic++) {
      value += Math.sin(2 * Math.PI * 100 * harmonic * time);
    }
    seed.value = (Math.imul(seed.value, 1664525) + 1013904223) >>> 0;
    const noise = ((seed.value % 1000) - 500) / 500;
    samples[index] = gain * (value / (harmonics[1] - harmonics[0] + 1) + 0.05 * noise);
  }
  return samples;
}

/** Dark voice: energy in low harmonics (300–800 Hz). */
const lowVoice = (seconds, seed, gain = 0.8) => voice(seconds, [3, 8], gain, seed);

/** Bright voice: energy in high harmonics (2500–4000 Hz). */
const highVoice = (seconds, seed, gain = 0.8) => voice(seconds, [25, 40], gain, seed);

test("too short audio has no voiceprint", () => {
  const seed = { value: 1 };

  assert.equal(extractVoiceprint(new Float32Array(0), RATE), null);
  assert.equal(extractVoiceprint(lowVoice(0.05, seed), RATE), null);
});

test("voiceprint does not depend on loudness", () => {
  const seed = { value: 1 };
  const loud = extractVoiceprint(lowVoice(3, seed, 0.8), RATE);
  const quiet = extractVoiceprint(lowVoice(3, seed, 0.05), RATE);

  assert.equal(loud.vector.length, BAND_COUNT);
  assert.ok(cosineSimilarity(loud.vector, quiet.vector) > 0.95);
  let norm = 0;
  for (const value of loud.vector) norm += value * value;
  assert.ok(Math.abs(norm - 1) < 1e-9);
  // 3 s give 298 frames; the loudest half of them is used.
  assert.equal(loud.frameCount, 149);
});

test("different voices get different voiceprints", () => {
  const seed = { value: 1 };
  const low = extractVoiceprint(lowVoice(3, seed), RATE);
  const high = extractVoiceprint(highVoice(3, seed), RATE);

  assert.ok(cosineSimilarity(low.vector, high.vector) < 0.5);
});

test("reference tells voices apart", () => {
  const seed = { value: 1 };
  const reference = new SpeakerReference();
  assert.equal(reference.isReady, false);
  assert.equal(reference.verdict([0.5, 0.5]), null);

  for (let example = 0; example < 3; example++) {
    reference.add(extractVoiceprint(lowVoice(3, seed), RATE).vector, "teacher");
    reference.add(extractVoiceprint(highVoice(3, seed), RATE).vector, "other");
  }
  assert.equal(reference.isReady, true);
  assert.equal(reference.teacherCount, 3);
  assert.equal(reference.otherCount, 3);

  const unknownLow = extractVoiceprint(lowVoice(2, seed), RATE).vector;
  const unknownHigh = extractVoiceprint(highVoice(2, seed), RATE).vector;

  assert.equal(reference.verdict(unknownLow).speaker, "teacher");
  assert.equal(reference.verdict(unknownHigh).speaker, "other");
  assert.equal(reference.verdict(null), null);
});

test("cosineSimilarity edge cases", () => {
  assert.equal(cosineSimilarity([], []), 0);
  assert.equal(cosineSimilarity([1, 0], [1, 0, 0]), 0);
  assert.equal(cosineSimilarity([0, 0], [1, 0]), 0);
  assert.ok(Math.abs(cosineSimilarity([1, 0], [0, 1])) < 1e-12);
});
