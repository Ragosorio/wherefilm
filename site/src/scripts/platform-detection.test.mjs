import assert from 'node:assert/strict';
import test from 'node:test';
import { classifyClientPlatform } from './platform-detection.mjs';

test('recognises Apple Silicon when client hints expose ARM', () => {
  assert.deepEqual(classifyClientPlatform({
    platform: 'macOS', userAgent: 'Mozilla/5.0 (Macintosh)', architecture: 'arm',
  }), { isMac: true, architecture: 'apple-silicon' });
});

test('recognises Intel when client hints expose x86', () => {
  assert.deepEqual(classifyClientPlatform({
    platform: 'macOS', userAgent: 'Mozilla/5.0 (Macintosh)', architecture: 'x86',
  }), { isMac: true, architecture: 'intel' });
});

test('keeps Safari Mac compatible when architecture is withheld', () => {
  assert.deepEqual(classifyClientPlatform({
    platform: 'MacIntel', userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
  }), { isMac: true, architecture: null });
});

test('does not mistake an iPad in desktop mode for a Mac', () => {
  assert.deepEqual(classifyClientPlatform({
    platform: 'MacIntel', userAgent: 'Mozilla/5.0 (Macintosh)', maxTouchPoints: 5,
  }), { isMac: false, architecture: null });
});

for (const [name, input] of [
  ['Windows', { platform: 'Win32', userAgent: 'Mozilla/5.0 (Windows NT 10.0)' }],
  ['Linux', { platform: 'Linux x86_64', userAgent: 'Mozilla/5.0 (X11; Linux x86_64)' }],
  ['iPhone', { platform: 'iPhone', userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)' }],
]) {
  test(`marks ${name} as unsupported`, () => {
    assert.deepEqual(classifyClientPlatform(input), { isMac: false, architecture: null });
  });
}
