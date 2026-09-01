/**
 * Classifies only signals a browser chose to expose. Architecture is optional:
 * Safari commonly withholds it, which is why WhereFilm ships one universal DMG.
 *
 * @param {{
 *   platform?: string,
 *   userAgent?: string,
 *   maxTouchPoints?: number,
 *   architecture?: string
 * }} input
 */
export function classifyClientPlatform(input) {
  const platform = input.platform ?? '';
  const userAgent = input.userAgent ?? '';
  const iPadInDesktopMode = platform === 'MacIntel' && (input.maxTouchPoints ?? 0) > 1;
  const isMac = !iPadInDesktopMode && (
    /mac/i.test(platform) || /Macintosh|Mac OS X/i.test(userAgent)
  );

  if (!isMac) return { isMac: false, architecture: null };

  const architecture = (input.architecture ?? '').toLowerCase();
  if (/arm|aarch/.test(architecture)) {
    return { isMac: true, architecture: 'apple-silicon' };
  }
  if (/x86|amd/.test(architecture)) {
    return { isMac: true, architecture: 'intel' };
  }
  return { isMac: true, architecture: null };
}
