// Hands the sound to the page in chunks of 512 frames (32 ms at 16 kHz).

const CHUNK_FRAMES = 512;

class CaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.chunk = new Float32Array(CHUNK_FRAMES);
    this.filled = 0;
  }

  process(inputs) {
    const input = inputs[0];
    const channel = input && input[0];
    if (channel) {
      let position = 0;
      while (position < channel.length) {
        const count = Math.min(channel.length - position, CHUNK_FRAMES - this.filled);
        this.chunk.set(channel.subarray(position, position + count), this.filled);
        this.filled += count;
        position += count;
        if (this.filled === CHUNK_FRAMES) {
          const full = this.chunk;
          this.port.postMessage(full, [full.buffer]);
          this.chunk = new Float32Array(CHUNK_FRAMES);
          this.filled = 0;
        }
      }
    }
    return true;
  }
}

registerProcessor("capture-processor", CaptureProcessor);
