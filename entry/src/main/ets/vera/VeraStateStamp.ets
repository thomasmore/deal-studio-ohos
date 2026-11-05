/** Keep the existing on-disk state contract identical in the app and form process. */
export function veraStateStamp(vbc2: string): string {
  return vbc2.length.toString() + ':' + vbc2.substring(0, 64)
}

/**
 * A short digest of an encoded state: two 32-bit FNV-1a hashes from different starting points, and the length. Equal states
 * give equal digests; a different state gives a different one but for a chance of about one in 2^64.
 */
export function stateDigest(text: string): string {
  let a = 0x811c9dc5
  let b = 0x01000193 ^ 0x5bd1e995
  for (let i = 0; i < text.length; i++) {
    let c = text.charCodeAt(i)
    a = Math.imul(a ^ c, 0x01000193) >>> 0
    b = Math.imul(b ^ c, 0x01000193) >>> 0
  }
  return text.length.toString(36) + '.' + a.toString(16) + b.toString(16)
}
