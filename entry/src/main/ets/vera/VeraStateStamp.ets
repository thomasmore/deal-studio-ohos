/** Keep the existing on-disk state contract identical in the app and form process. */
export function veraStateStamp(vbc2: string): string {
  return vbc2.length.toString() + ':' + vbc2.substring(0, 64)
}
