// Computes voiceprints away from the page so that the sound level keeps moving smoothly.
import { extractVoiceprint } from "./voiceprint.js";

self.onmessage = (event) => {
  const { requestId, samples, sampleRate } = event.data;
  const voiceprint = extractVoiceprint(samples, sampleRate);
  self.postMessage({
    requestId,
    voiceprint: voiceprint ? { vector: Array.from(voiceprint.vector), levelDb: voiceprint.levelDb, frameCount: voiceprint.frameCount } : null,
  });
};
