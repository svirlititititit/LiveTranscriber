// Port of Voiceprint.swift and Transcript.swift (SpeakerReference).
import { decibelsFromRMS, powerSpectrum } from "./dsp.js";

export const BAND_COUNT = 26;
const MINIMUM_FRAME_COUNT = 10;

/**
 * Computes a rough "voiceprint" of an utterance given as mono samples: the average
 * spectrum of its loudest frames. It separates speakers only approximately (by voice
 * timbre and by how far away the sound source is), so its verdicts are hints.
 * Returns `null` when there is too little audio.
 */
export function extractVoiceprint(samples, sampleRate) {
  if (sampleRate <= 0) return null;

  const frameSize = Math.max(64, Math.round(sampleRate * 0.025));
  const hop = Math.max(1, Math.round(sampleRate * 0.010));
  const fftSize = 512;
  if (samples.length < MINIMUM_FRAME_COUNT * hop) return null;

  const filterbank = melFilterbank(BAND_COUNT, fftSize, sampleRate);
  const window = hannWindow(frameSize);

  // Windowed frames together with their loudness.
  const frames = [];
  for (let start = 0; start + frameSize <= samples.length; start += hop) {
    let energy = 0;
    const frame = new Float64Array(frameSize);
    for (let index = 0; index < frameSize; index++) {
      const sample = samples[start + index];
      energy += sample * sample;
      frame[index] = sample * window[index];
    }
    frames.push({ samples: frame, rms: Math.sqrt(energy / frameSize) });
  }
  if (frames.length < MINIMUM_FRAME_COUNT) return null;

  // Silence and quiet pauses say nothing about the speaker: use the loudest half.
  const loudest = frames.map((frame, index) => index)
    .sort((a, b) => frames[b].rms - frames[a].rms);
  const usedCount = Math.max(MINIMUM_FRAME_COUNT, Math.floor(frames.length / 2));

  const bandSums = new Float64Array(filterbank.length);
  let levelSum = 0;
  for (let used = 0; used < usedCount; used++) {
    const frame = frames[loudest[used]];
    const power = powerSpectrum(frame.samples, fftSize);
    for (let band = 0; band < filterbank.length; band++) {
      const weights = filterbank[band];
      let energy = 0;
      for (let bin = 0; bin < power.length; bin++) {
        if (weights[bin] !== 0) energy += weights[bin] * power[bin];
      }
      bandSums[band] += Math.log10(Math.max(energy, 1e-12));
    }
    levelSum += decibelsFromRMS(frame.rms);
  }

  // Remove the overall loudness so that only the spectral shape is left.
  const vector = new Float64Array(bandSums.length);
  let mean = 0;
  for (let band = 0; band < bandSums.length; band++) {
    vector[band] = bandSums[band] / usedCount;
    mean += vector[band];
  }
  mean /= vector.length;
  let norm = 0;
  for (let band = 0; band < vector.length; band++) {
    vector[band] -= mean;
    norm += vector[band] * vector[band];
  }
  norm = Math.sqrt(norm);
  if (norm <= 1e-6) return null;
  for (let band = 0; band < vector.length; band++) {
    vector[band] /= norm;
  }

  return { vector, levelDb: levelSum / usedCount, frameCount: usedCount };
}

/** Cosine similarity of two vectors of equal length: -1...1. */
export function cosineSimilarity(a, b) {
  if (!a || !b || a.length === 0 || a.length !== b.length) return 0;
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let index = 0; index < a.length; index++) {
    dot += a[index] * b[index];
    normA += a[index] * a[index];
    normB += b[index] * b[index];
  }
  if (normA <= 0 || normB <= 0) return 0;
  return dot / Math.sqrt(normA * normB);
}

/**
 * Examples of the teacher's and of other voices, collected from utterances the user
 * labelled. New utterances are compared with both averages.
 */
export class SpeakerReference {
  constructor() {
    /** When both averages are this close, the utterance stays unlabelled. */
    this.minimumGap = 0.02;
    this.teacherSum = null;
    this.otherSum = null;
    this.teacherCount = 0;
    this.otherCount = 0;
  }

  get isReady() {
    return this.teacherCount > 0 && this.otherCount > 0;
  }

  add(vector, speaker) {
    if (!vector || vector.length === 0 || (speaker !== "teacher" && speaker !== "other")) return;
    if (this.teacherSum === null) {
      this.teacherSum = new Float64Array(vector.length);
      this.otherSum = new Float64Array(vector.length);
    }
    if (vector.length !== this.teacherSum.length) return;

    const sum = speaker === "teacher" ? this.teacherSum : this.otherSum;
    for (let index = 0; index < vector.length; index++) {
      sum[index] += vector[index];
    }
    if (speaker === "teacher") {
      this.teacherCount += 1;
    } else {
      this.otherCount += 1;
    }
  }

  /** Returns `{ speaker, teacherSimilarity, otherSimilarity }` or `null`. */
  verdict(vector) {
    if (!this.isReady || !vector || vector.length !== this.teacherSum.length) return null;
    const teacher = cosineSimilarity(vector, this.teacherSum);
    const other = cosineSimilarity(vector, this.otherSum);
    if (Math.abs(teacher - other) < this.minimumGap) {
      return { speaker: "unknown", teacherSimilarity: teacher, otherSimilarity: other };
    }
    return {
      speaker: teacher > other ? "teacher" : "other",
      teacherSimilarity: teacher,
      otherSimilarity: other,
    };
  }
}

function hzToMel(hertz) {
  return 2595 * Math.log10(1 + hertz / 700);
}

function melToHz(mel) {
  return 700 * (Math.pow(10, mel / 2595) - 1);
}

function hannWindow(count) {
  const window = new Float64Array(count);
  for (let index = 0; index < count; index++) {
    window[index] = 0.5 * (1 - Math.cos((2 * Math.PI * index) / count));
  }
  return window;
}

/** Triangular filters evenly spaced on the mel scale between 150 Hz and 6 kHz. */
function melFilterbank(bandCount, fftSize, sampleRate) {
  const binCount = fftSize / 2;
  const low = hzToMel(150);
  const high = hzToMel(Math.min(6000, (sampleRate / 2) * 0.95));
  const points = [];
  for (let index = 0; index <= bandCount + 1; index++) {
    points.push(melToHz(low + ((high - low) * index) / (bandCount + 1)));
  }

  return Array.from({ length: bandCount }, (_, band) => {
    const left = points[band];
    const center = points[band + 1];
    const right = points[band + 2];
    const weights = new Float64Array(binCount);
    for (let bin = 0; bin < binCount; bin++) {
      const hertz = (bin * sampleRate) / fftSize;
      if (hertz <= left || hertz >= right) continue;
      weights[bin] = hertz <= center ? (hertz - left) / (center - left) : (right - hertz) / (right - center);
    }
    return weights;
  });
}
