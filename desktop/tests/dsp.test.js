// Tests for dsp.js, ported from Tests/LessonCoreTests/DSPTests.swift.
import assert from "node:assert/strict";
import test from "node:test";
import { decibelsFromRMS, fft, powerSpectrum, resample, rootMeanSquare } from "../web/dsp.js";

test("powerSpectrum finds the dominant frequency", () => {
  const sampleRate = 16000;
  const signal = Float32Array.from({ length: 512 }, (_, index) =>
    Math.sin((2 * Math.PI * 1000 * index) / sampleRate));

  const power = powerSpectrum(signal, 512);

  assert.equal(power.length, 256);
  assert.equal(argMax(power), 32);
});

test("fft matches the naive DFT", () => {
  const count = 64;
  let seed = 1;
  const random = () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return (seed % 2001) / 1000 - 1;
  };
  const real = Float64Array.from({ length: count }, random);
  const imaginary = new Float64Array(count);

  const fastReal = Float64Array.from(real);
  const fastImaginary = Float64Array.from(imaginary);
  fft(fastReal, fastImaginary);

  for (let bin = 0; bin < count; bin++) {
    let expectedReal = 0;
    let expectedImaginary = 0;
    for (let time = 0; time < count; time++) {
      const angle = (-2 * Math.PI * bin * time) / count;
      expectedReal += real[time] * Math.cos(angle) - imaginary[time] * Math.sin(angle);
      expectedImaginary += real[time] * Math.sin(angle) + imaginary[time] * Math.cos(angle);
    }
    assert.ok(Math.abs(fastReal[bin] - expectedReal) < 1e-9, `bin ${bin} real`);
    assert.ok(Math.abs(fastImaginary[bin] - expectedImaginary) < 1e-9, `bin ${bin} imaginary`);
  }
});

test("resample keeps the length and the signal", () => {
  const sourceRate = 48000;
  const signal = Float32Array.from({ length: 48000 }, (_, index) =>
    Math.sin((2 * Math.PI * 400 * index) / sourceRate));

  const resampled = resample(signal, sourceRate, 16000);

  assert.equal(resampled.length, 16000);
  const power = powerSpectrum(resampled.subarray(0, 512), 512);
  const peak = argMax(power);
  assert.ok(peak >= 11 && peak <= 14, `peak bin ${peak}`);
  assert.ok(Math.max(...resampled.map(Math.abs)) > 0.9);
});

test("resample handles a non-integer ratio", () => {
  const resampled = resample(new Float32Array(44100).fill(0.5), 44100, 16000);

  assert.ok(Math.abs(resampled.length - 16000) <= 1);
  assert.ok(Math.abs(resampled[0] - 0.5) < 1e-6);
});

test("resample of a matching rate returns the input untouched", () => {
  const signal = new Float32Array([0.1, 0.2, 0.3]);
  assert.equal(resample(signal, 16000, 16000), signal);
});

test("decibels", () => {
  assert.ok(Math.abs(decibelsFromRMS(1)) < 1e-9);
  assert.ok(Math.abs(decibelsFromRMS(0.1) + 20) < 1e-9);
  assert.ok(decibelsFromRMS(0) <= -190);
  assert.ok(Math.abs(rootMeanSquare(new Float32Array([0.5, -0.5, 0.5, -0.5])) - 0.5) < 1e-6);
});

function argMax(values) {
  let best = 0;
  for (let index = 1; index < values.length; index++) {
    if (values[index] > values[best]) best = index;
  }
  return best;
}
