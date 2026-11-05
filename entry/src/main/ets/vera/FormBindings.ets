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
  let file = fs.openSync(temp, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
  try { fs.writeSync(file.fd, text) } finally { fs.closeSync(file) }
  try { fs.renameSync(temp, path) } finally {
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
