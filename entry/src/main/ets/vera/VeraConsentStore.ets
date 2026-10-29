/**
 * What the person has already allowed a program to do.
 *
 * Asking once is protection; asking every time is a habit of clicking Allow,
 * which is the opposite. So a grant is remembered -- but narrowly, and the
 * narrowness is the whole design:
 *
 *   per program, not per phone. Another generated app asking for the same
 *   intent is a different question and gets asked again.
 *
 *   per call, not per app. Allowing "turn the torch on" says nothing about
 *   "send a message", even inside the same program.
 *
 *   per version of the program. The key carries the bytecode stamp, so the
 *   moment the program is regenerated or refined every grant it held is gone.
 *   A person allowed *that* program to do it; the new one has not asked yet.
 *
 * Kept in {filesDir}/vera/consent.json, beside the saved state it belongs
 * with. Losing the file loses nothing but the convenience: every call simply
 * asks again.
 */

import { fileIo as fs } from '@kit.CoreFileKit'
import { hilog } from '@kit.PerformanceAnalysisKit'

const DOMAIN = 0x0000

function readText(path: string): string {
  try {
    let stat = fs.statSync(path)
    if (stat.size === 0) { return '' }
    return fs.readTextSync(path)
  } catch (_e) {
    return ''
  }
}

export class ConsentStore {
  private root: string = ''
  private granted: Map<string, boolean> = new Map<string, boolean>()
  private loaded: boolean = false

  init(filesDir: string): void {
    if (this.root.length > 0) { return }
    this.root = filesDir + '/vera'
    try { fs.mkdirSync(this.root, true) } catch (_e) {}
    this.load()
  }

  private path(): string { return this.root + '/consent.json' }

  private load(): void {
    if (this.loaded || this.root.length === 0) { return }
    this.loaded = true
    let text = readText(this.path())
    if (text.length === 0) { return }
    try {
      let obj = JSON.parse(text) as Record<string, Object>
      for (let key of Object.keys(obj)) {
        if (obj[key] === true) { this.granted.set(key, true) }
      }
    } catch (_e) {
      // A file we cannot read is a file we ignore: the cost is one dialog.
    }
  }

  private save(): void {
    if (this.root.length === 0) { return }
    let obj: Record<string, Object> = {}
    this.granted.forEach((_value: boolean, key: string) => { obj[key] = true })
    try {
      let file = fs.openSync(this.path(),
        fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, JSON.stringify(obj))
      fs.closeSync(file)
    } catch (e) {
      hilog.warn(DOMAIN, 'VERA', 'VERA-CONSENT could not be saved: ' + (e as Error).message)
    }
  }

  /**
   * The stamp is the program, the target is the call. Both, always: a key that
   * forgot either half would grant more than the person was shown.
   */
  private key(stamp: string, target: string): string { return stamp + '|' + target }

  has(stamp: string, target: string): boolean {
    if (this.root.length === 0 || stamp.length === 0) { return false }
    this.load()
    return this.granted.get(this.key(stamp, target)) === true
  }

  remember(stamp: string, target: string): void {
    if (this.root.length === 0 || stamp.length === 0) { return }
    this.load()
    this.granted.set(this.key(stamp, target), true)
    this.save()
    hilog.info(DOMAIN, 'VERA', 'VERA-CONSENT remembered ' + target)
  }

  /** Everything this program was allowed, dropped. For "ask me again". */
  forget(stamp: string): void {
    if (this.root.length === 0 || stamp.length === 0) { return }
    this.load()
    let doomed: string[] = []
    this.granted.forEach((_value: boolean, key: string) => {
      if (key.startsWith(stamp + '|')) { doomed.push(key) }
    })
    for (let key of doomed) { this.granted.delete(key) }
    if (doomed.length > 0) {
      this.save()
      hilog.info(DOMAIN, 'VERA', 'VERA-CONSENT forgot ' + doomed.length.toString() + ' grants')
    }
  }
}

export const consent: ConsentStore = new ConsentStore()
