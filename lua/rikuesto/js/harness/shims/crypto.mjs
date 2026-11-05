// crypto shim: the subset of the http-files spec, mapped onto `node:crypto`,
// which Deno provides through its Node compatibility layer (no npm packages).
import { createHash, createHmac } from 'node:crypto';

function asInput(value) {
  if (typeof value === 'string') {
    return value;
  }
  if (value instanceof Uint8Array) {
    return value;
  }
  return JSON.stringify(value);
}

function hashHex(algorithm, data) {
  return createHash(algorithm).update(asInput(data)).digest('hex');
}

function hmacHex(algorithm, key, data) {
  return createHmac(algorithm, asInput(key)).update(asInput(data)).digest('hex');
}

const hmac = {
  sha256: (key, data) => hmacHex('sha256', key, data),
  sha512: (key, data) => hmacHex('sha512', key, data),
};

export default {
  hmac,
  sha256: (data) => hashHex('sha256', data),
  sha512: (data) => hashHex('sha512', data),
};
