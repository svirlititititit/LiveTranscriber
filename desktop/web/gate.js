// Port of SpeechGate.swift: splits the audio stream into utterances by sound level.
// Speech starts when the level rises clearly above the tracked noise floor and ends
// after a long enough dip.

const RELEASE_SECONDS = 0.08;
const END_HYSTERESIS_DB = 2;

export const DEFAULT_GATE_SETTINGS = Object.freeze({
  /** How much louder than the noise floor a sound must be to count as speech, dB. */
  marginDb: 8,
  /** Sounds quieter than this are never counted as speech, dBFS. */
  minimumLevelDb: -55,
  /** How long a sound must stay loud before it counts as the start of an utterance, s. */
  startHoldSeconds: 0.12,
  /** How long the sound must stay quiet before the utterance is considered finished, s. */
  pauseSeconds: 0.8,
});

export class SpeechGate {
  constructor(settings = {}) {
    this.settings = { ...DEFAULT_GATE_SETTINGS, ...settings };
    /** Smoothed level of the latest chunk, dBFS. */
    this.levelDb = -100;
    /** Tracked level of the background noise, dBFS. */
    this.noiseFloorDb = -60;
    /** Level above which sound counts as speech, dBFS. */
    this.thresholdDb = -55;
    this.isSpeechActive = false;

    this.loudTime = 0;
    this.quietTime = 0;
  }

  updateSettings(settings) {
    Object.assign(this.settings, settings);
  }

  reset() {
    this.levelDb = -100;
    this.noiseFloorDb = -60;
    this.thresholdDb = -55;
    this.isSpeechActive = false;
    this.loudTime = 0;
    this.quietTime = 0;
  }

  /** Feeds one chunk of mono audio and returns the events it produced. */
  process(samples, sampleRate) {
    if (samples.length === 0 || sampleRate <= 0) return [];
    const duration = samples.length / sampleRate;
    const chunkDb = decibels(rootMeanSquare(samples));
    const settings = this.settings;

    // React to sound instantly, fade out quickly.
    if (chunkDb >= this.levelDb) {
      this.levelDb = chunkDb;
    } else {
      const decay = Math.exp(-duration / RELEASE_SECONDS);
      this.levelDb = chunkDb + (this.levelDb - chunkDb) * decay;
    }

    // Track the noise floor: drop right away when it gets quieter, creep up slowly
    // (slower still during speech, so that speech is not mistaken for noise).
    if (this.levelDb <= this.noiseFloorDb) {
      this.noiseFloorDb = this.levelDb;
    } else {
      const rise = (this.isSpeechActive ? 1.0 : 6.0) * duration;
      this.noiseFloorDb = Math.min(this.levelDb, this.noiseFloorDb + rise);
    }
    this.thresholdDb = Math.max(this.noiseFloorDb + settings.marginDb, settings.minimumLevelDb);

    const events = [];
    if (this.isSpeechActive) {
      if (this.levelDb < this.thresholdDb - END_HYSTERESIS_DB) {
        this.quietTime += duration;
        if (this.quietTime >= settings.pauseSeconds) {
          this.isSpeechActive = false;
          this.quietTime = 0;
          events.push("speechEnded");
        }
      } else {
        this.quietTime = 0;
      }
    } else if (chunkDb > this.thresholdDb) {
      // The start is judged by the raw level: the smoothed one keeps ringing after
      // a short click and would count it as the beginning of speech.
      this.loudTime += duration;
      if (this.loudTime >= settings.startHoldSeconds) {
        this.isSpeechActive = true;
        this.loudTime = 0;
        this.quietTime = 0;
        events.push("speechStarted");
      }
    } else {
      this.loudTime = Math.max(0, this.loudTime - duration);
    }
    return events;
  }

  /**
   * Ends the current utterance right away without leaving the "speech" state, so that
   * no new start event is emitted (used when an utterance grows too long).
   */
  forceEnd() {
    this.quietTime = 0;
  }
}

function rootMeanSquare(samples) {
  let energy = 0;
  for (let index = 0; index < samples.length; index++) {
    energy += samples[index] * samples[index];
  }
  return Math.sqrt(energy / samples.length);
}

function decibels(rms) {
  return 20 * Math.log10(Math.max(rms, 1e-10));
}
