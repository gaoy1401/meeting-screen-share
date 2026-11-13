export class RateLimiter {
  constructor({ bytesPerSecond, burstBytes }) {
    this.bytesPerSecond = bytesPerSecond;
    this.burstBytes = burstBytes;
    this.buckets = new Map();
  }

  allow(key, byteCount, now = Date.now()) {
    let bucket = this.buckets.get(key);
    if (!bucket) {
      bucket = { tokens: this.burstBytes, updatedAt: now };
      this.buckets.set(key, bucket);
    }

    const elapsedSeconds = Math.max(0, now - bucket.updatedAt) / 1000;
    bucket.tokens = Math.min(
      this.burstBytes,
      bucket.tokens + elapsedSeconds * this.bytesPerSecond
    );
    bucket.updatedAt = now;

    if (byteCount > bucket.tokens) return false;
    bucket.tokens -= byteCount;
    return true;
  }

  remove(key) {
    this.buckets.delete(key);
  }
}

