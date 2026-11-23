import { fileIo as fs } from '@kit.CoreFileKit'

/** Reload on every operation: the UI and form extension run in different processes. */
export class FormBindings {
  private path: string = ''

  init(filesDir: string): void {
    let root = filesDir + '/vera'
    try { fs.mkdirSync(root, true) } catch (_e) {}
    this.path = root + '/forms.json'
  }

  private read(): Record<string, string> {
    if (this.path.length === 0) { throw new Error('Form bindings are not initialised') }
    try { return JSON.parse(fs.readTextSync(this.path)) as Record<string, string> } catch (_e) { return {} }
  }

  projectFor(formId: string): string { return this.read()[formId] || '' }

  /** How many cards show each project, read once: for a list of projects. */
  countsByProject(): Record<string, number> {
    let entries = this.read()
    let counts: Record<string, number> = {}
    for (let id of Object.keys(entries)) { counts[entries[id]] = (counts[entries[id]] || 0) + 1 }
    return counts
  }

  formsFor(projectId: string): string[] {
    let entries = this.read()
    return Object.keys(entries).filter((id: string): boolean => entries[id] === projectId)
  }

  bind(formId: string, projectId: string): void {
    if (formId.length === 0 || projectId.length === 0) { throw new Error('Missing form or project ID') }
    let entries = this.read()
    entries[formId] = projectId
    this.write(entries)
  }

  unbind(formId: string): void {
    let entries = this.read()
    let kept: Record<string, string> = {}
    for (let id of Object.keys(entries)) { if (id !== formId) { kept[id] = entries[id] } }
    this.write(kept)
    this.setDimension(formId, 0)
  }

  /** The size a card was added at, as the system numbers it (2 is 2x2, 3 is 2x4, 4 is 4x4); 2 when it never said. */
  dimensionFor(formId: string): number {
    try {
      let sizes = JSON.parse(fs.readTextSync(this.sizesPath())) as Record<string, number>
      let known = sizes[formId]
      return known === 3 || known === 4 ? known : 2
    } catch (_e) { return 2 }
  }

  /** Kept beside the bindings; 0 forgets it (a card that was removed). */
  setDimension(formId: string, dimension: number): void {
    if (formId.length === 0) { return }
    let sizes: Record<string, number> = {}
    try { sizes = JSON.parse(fs.readTextSync(this.sizesPath())) as Record<string, number> } catch (_e) {}
    let kept: Record<string, number> = {}
    for (let id of Object.keys(sizes)) { if (id !== formId) { kept[id] = sizes[id] } }
    if (dimension === 2 || dimension === 3 || dimension === 4) { kept[formId] = dimension }
    writeAtomically(this.sizesPath(), JSON.stringify(kept))
  }

  private sizesPath(): string {
    if (this.path.length === 0) { throw new Error('Form bindings are not initialised') }
    return this.path.replace(/forms\.json$/, 'form-sizes.json')
  }

  private write(entries: Record<string, string>): void {
    writeAtomically(this.path, JSON.stringify(entries))
  }

  /**
   * Add widget, where the system widget manager adds the card: the manager does not pass our parameters on, so the
   * project waits here for the next live card added within OFFER_MS.
   */
  offer(projectId: string, at: number = Date.now()): void {
    let offer: Record<string, Object> = {}
    offer['projectId'] = projectId
    offer['at'] = at
    writeAtomically(this.offerPath(), JSON.stringify(offer))
  }

  /** The project offered for a card added now, once: a later card is not bound to it. */
  takeOffer(now: number = Date.now()): string {
    let offer: Record<string, Object> = {}
    try { offer = JSON.parse(fs.readTextSync(this.offerPath())) as Record<string, Object> } catch (_e) { return '' }
    try { fs.unlinkSync(this.offerPath()) } catch (_e) {}
    let at = offer['at']
    let projectId = offer['projectId']
    if (typeof at !== 'number' || typeof projectId !== 'string' || now - at < 0 || now - at > OFFER_MS) { return '' }
    return projectId
  }

  private offerPath(): string {
    if (this.path.length === 0) { throw new Error('Form bindings are not initialised') }
    return this.path.replace(/forms\.json$/, 'form-offer.json')
  }
}

/** How long Add widget waits for the card to be placed in the system widget manager. */
export const OFFER_MS: number = 5 * 60 * 1000

/** A sibling written whole, then renamed over the file: a reader in the other process sees the old file or the new one. */
function writeAtomically(path: string, text: string): void {
  let temp = path + '.' + Date.now().toString() + '.' + Math.random().toString().substring(2) + '.tmp'
  try {
    let file: fs.File | null = null
    let failed = false
    try {
      file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, text)
    } catch (e) {
      failed = true
      throw e as Error
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file)
        } catch (e) {
          if (!failed) { throw e as Error }
        }
      }
    }
    fs.renameSync(temp, path)
  } catch (e) {
    throw e as Error
  } finally {
    try { fs.unlinkSync(temp) } catch (_e) {}
  }
}

export const formBindings: FormBindings = new FormBindings()

/**
 * When each project's widgetRefresh last ran, in Unix ms. The system updates every card on its own schedule; a project shown
 * on two cards is still brought up to date once per period, not once per card.
 */
export class RefreshLedger {
  private path: string = ''

  init(filesDir: string): void {
    let root = filesDir + '/vera'
    try { fs.mkdirSync(root, true) } catch (_e) {}
    this.path = root + '/widget-refresh.json'
  }

  private read(): Record<string, number> {
    if (this.path.length === 0) { throw new Error('Widget refresh ledger is not initialised') }
    try { return JSON.parse(fs.readTextSync(this.path)) as Record<string, number> } catch (_e) { return {} }
  }

  lastRun(projectId: string): number {
    let at = this.read()[projectId]
    return typeof at === 'number' ? at : 0
  }

  markRun(projectId: string, at: number): void {
    let entries = this.read()
    entries[projectId] = at
    writeAtomically(this.path, JSON.stringify(entries))
  }
}

export const refreshLedger: RefreshLedger = new RefreshLedger()
