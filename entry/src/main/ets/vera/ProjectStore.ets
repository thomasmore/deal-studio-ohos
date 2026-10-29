import { fileIo as fs } from '@kit.CoreFileKit'
import { requestHeadline } from './ProjectText'


export class Project {
  id: string = ''
  name: string = ''
  icon: string = ''
  createdAt: number = 0
}

/** What the project list shows of a project, without opening each of its versions every time it is drawn. */
export class ProjectSummary {
  versions: number = 0
  /** The request the latest version began as. */
  request: string = ''
  /** When it was last worked on: its latest version, or its creation when it has none. */
  updatedAt: number = 0
}

export class VersionMetrics {
  provider: string = ''
  model: string = ''
  elapsedMs: number = 0
  runs: number = 0
  attempts: number = 0
  inputTokens: number = -1
  cacheHitTokens: number = -1
  outputTokens: number = -1
  estimatedUsd: number = -1
  partial: boolean = true
}

export class Version {
  id: string = ''
  projectId: string = ''
  source: string = ''
  vbc2: string = ''
  /** Short label for the version list. */
  note: string = ''
  /**
   * The request that produced this version, in full. `note` is a truncation of
   * it for the list, and used to be all that was kept -- so the instruction a
   * program was built from was lost as soon as it exceeded a hundred characters.
   */
  prompt: string = ''
  lastPrompt: string = ''
  parentVersionId: string = ''
  /**
   * How the version came about when it began as a composed template: the section kinds Jev chose,
   * comma-separated ("record_log,bar_chart"), with "+model" appended when the model then rewrote
   * it. Empty for a program written from scratch and for versions saved before this was kept.
   */
  origin: string = ''
  /**
   * The composition record (VeraComposition.ets) as JSON when this version is a composed screen the
   * model has not rewritten: what a structural edit rebuilds the program from. Empty otherwise.
   */
  composition: string = ''
  metrics: VersionMetrics | null = null
  createdAt: number = 0
}

function generateId(): string {
  let now = Date.now()
  let rand = Math.floor(Math.random() * 0xFFFFFF)
  return now.toString(36) + rand.toString(36)
}

function ensureDir(path: string): void {
  try { fs.mkdirSync(path, true) } catch (_e) {}
}

function readJson(path: string): string {
  try {
    let stat = fs.statSync(path)
    if (stat.size === 0) { return '' }
    return fs.readTextSync(path)
  } catch (_e) {
    return ''
  }
}

function writeJson(path: string, content: string): void {
  let file: fs.File | null = null
  let failed = false
  try {
    file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC)
    fs.writeSync(file.fd, content)
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
}

function removeRecursive(path: string): void {
  try { fs.rmdirSync(path) } catch (_e) {}
}

export class ProjectStore {
  private root: string = ''

  init(filesDir: string): void {
    this.root = filesDir + '/vera'
    ensureDir(this.root)
  }

  private indexPath(): string { return this.root + '/index.json' }
  private projectDir(id: string): string { return this.root + '/' + id }
  private versionPath(projectId: string, versionId: string): string {
    return this.projectDir(projectId) + '/' + versionId + '.json'
  }

  /**
   * Saved program state lives beside its version rather than inside it, so
   * rewriting a version's bytecode cannot clobber the record, and deleting a
   * version takes its state with it.
   */
  private statePath(projectId: string, versionId: string): string {
    return this.projectDir(projectId) + '/' + versionId + '.state.json'
  }

  /**
   * The stamp ties saved state to the exact program that produced it. Refining a
   * program changes its bytecode, and the old state may no longer fit the new
   * AppState shape, so a mismatched stamp means start clean rather than restore
   * something that will trap on the first field access.
   */
  saveState(projectId: string, versionId: string, stamp: string, encoded: string): void {
    ensureDir(this.projectDir(projectId))
    let payload: Record<string, Object> = {}
    payload['stamp'] = stamp
    payload['value'] = JSON.parse(encoded) as Object
    writeJson(this.statePath(projectId, versionId), JSON.stringify(payload))
  }

  /** Returns the encoded value, or '' when there is nothing usable to restore. */
  loadState(projectId: string, versionId: string, stamp: string): string {
    let text = readJson(this.statePath(projectId, versionId))
    if (text.length === 0) { return '' }
    try {
      let obj = JSON.parse(text) as Record<string, Object>
      if ((obj['stamp'] as string) !== stamp) { return '' }
      return JSON.stringify(obj['value'])
    } catch (_e) {
      return ''
    }
  }

  clearState(projectId: string, versionId: string): void {
    try { fs.unlinkSync(this.statePath(projectId, versionId)) } catch (_e) {}
  }

  private readIndex(): Project[] {
    let text = readJson(this.indexPath())
    if (text.length === 0) { return [] }
    try {
      let arr = JSON.parse(text) as Object[]
      let result: Project[] = []
      for (let item of arr) {
        let p = new Project()
        let obj = item as Record<string, Object>
        p.id = obj['id'] as string
        p.name = obj['name'] as string
        p.icon = obj['icon'] as string
        p.createdAt = obj['createdAt'] as number
        result.push(p)
      }
      return result
    } catch (_e) { return [] }
  }

  private writeIndex(projects: Project[]): void {
    let arr: Object[] = []
    for (let p of projects) {
      let obj: Record<string, Object> = {}
      obj['id'] = p.id
      obj['name'] = p.name
      obj['icon'] = p.icon
      obj['createdAt'] = p.createdAt
      arr.push(obj)
    }
    writeJson(this.indexPath(), JSON.stringify(arr))
  }

  listProjects(): Project[] {
    return this.readIndex()
  }

  /** Per project, read from its versions once and kept until a version is saved or deleted. */
  private summaries: Map<string, ProjectSummary> = new Map<string, ProjectSummary>()

  summaryOf(project: Project): ProjectSummary {
    let known = this.summaries.get(project.id)
    if (known !== undefined) { return known }
    let versions = this.listVersions(project.id)
    let summary = new ProjectSummary()
    summary.versions = versions.length
    summary.updatedAt = project.createdAt
    if (versions.length > 0) {
      summary.updatedAt = Math.max(project.createdAt, versions[0].createdAt)
      summary.request = requestHeadline(versions[0].prompt, versions[0].note)
    }
    this.summaries.set(project.id, summary)
    return summary
  }

  getProject(id: string): Project | null {
    let projects = this.readIndex()
    for (let p of projects) {
      if (p.id === id) { return p }
    }
    return null
  }

  createProject(name: string, icon: string): Project {
    let p = new Project()
    p.id = generateId()
    p.name = name
    p.icon = icon
    p.createdAt = Date.now()
    let projects = this.readIndex()
    projects.push(p)
    this.writeIndex(projects)
    ensureDir(this.projectDir(p.id))
    return p
  }

  updateProject(id: string, name: string, icon: string): void {
    let projects = this.readIndex()
    for (let p of projects) {
      if (p.id === id) {
        p.name = name
        p.icon = icon
        break
      }
    }
    this.writeIndex(projects)
  }

  deleteProject(id: string): void {
    let projects = this.readIndex()
    if (!projects.some((p: Project) => p.id === id)) { return }
    let filtered: Project[] = []
    for (let p of projects) {
      if (p.id !== id) { filtered.push(p) }
    }
    this.writeIndex(filtered)
    removeRecursive(this.projectDir(id))
    this.summaries.delete(id)
  }

  listVersions(projectId: string): Version[] {
    let dir = this.projectDir(projectId)
    let versions: Version[] = []
    try {
      let files = fs.listFileSync(dir)
      for (let file of files) {
        // Saved program state lives in this directory too, as
        // `<versionId>.state.json` -- which also ends in `.json`. Without this
        // it was read as a version record, and because parseVersion only
        // returned null on a JSON syntax error, the result was a phantom entry
        // in the version list: no date, no bytecode, badged "needs compile".
        if (!file.endsWith('.json') || file.endsWith('.state.json')) { continue }
        let text = readJson(dir + '/' + file)
        if (text.length === 0) { continue }
        let v = this.parseVersion(text)
        if (v !== null) { versions.push(v!) }
      }
    } catch (_e) {}
    versions.sort((a: Version, b: Version): number => b.createdAt - a.createdAt)
    return versions
  }

  getVersion(projectId: string, versionId: string): Version | null {
    let text = readJson(this.versionPath(projectId, versionId))
    if (text.length === 0) { return null }
    return this.parseVersion(text)
  }

  getLatestRunnableVersion(projectId: string): Version | null {
    let versions = this.listVersions(projectId)
    for (let version of versions) {
      if (version.vbc2.length > 0) { return version }
    }
    return null
  }

  getLatestVersion(projectId: string): Version | null {
    let versions = this.listVersions(projectId)
    if (versions.length === 0) { return null }
    return versions[0]
  }

  createVersion(projectId: string, source: string, vbc2: string, note: string,
      prompt: string = '', origin: string = '', composition: string = '',
      lastPrompt: string = '', parentVersionId: string = '', metrics: VersionMetrics | null = null): Version {
    ensureDir(this.projectDir(projectId))
    let v = new Version()
    v.id = generateId()
    v.projectId = projectId
    v.source = source
    v.vbc2 = vbc2
    v.note = note
    v.prompt = prompt.length > 0 ? prompt : note
    v.lastPrompt = lastPrompt.length > 0 ? lastPrompt : v.prompt
    v.parentVersionId = parentVersionId
    v.origin = origin
    v.composition = composition
    v.metrics = metrics
    v.createdAt = Date.now()
    let obj: Record<string, Object> = {}
    obj['id'] = v.id
    obj['projectId'] = v.projectId
    obj['source'] = v.source
    obj['vbc2'] = v.vbc2
    obj['note'] = v.note
    obj['prompt'] = v.prompt
    obj['lastPrompt'] = v.lastPrompt
    obj['parentVersionId'] = v.parentVersionId
    obj['origin'] = v.origin
    obj['composition'] = v.composition
    if (v.metrics !== null) { obj['metrics'] = v.metrics }
    obj['createdAt'] = v.createdAt
    writeJson(this.versionPath(projectId, v.id), JSON.stringify(obj))
    this.summaries.delete(projectId)
    return v
  }

  updateVersionVbc2(projectId: string, versionId: string, vbc2: string): void {
    let v = this.getVersion(projectId, versionId)
    if (v === null) { return }
    v!.vbc2 = vbc2
    let obj: Record<string, Object> = {}
    obj['id'] = v!.id
    obj['projectId'] = v!.projectId
    obj['source'] = v!.source
    obj['vbc2'] = v!.vbc2
    obj['note'] = v!.note
    // Rewriting the bytecode must not drop the request this version came from.
    obj['prompt'] = v!.prompt
    obj['lastPrompt'] = v!.lastPrompt
    obj['parentVersionId'] = v!.parentVersionId
    obj['origin'] = v!.origin
    obj['composition'] = v!.composition
    if (v!.metrics !== null) { obj['metrics'] = v!.metrics! }
    obj['createdAt'] = v!.createdAt
    writeJson(this.versionPath(projectId, versionId), JSON.stringify(obj))
  }

  deleteVersion(projectId: string, versionId: string): boolean {
    let versions = this.listVersions(projectId)
    let found = false
    for (let v of versions) {
      if (v.id === versionId) { found = true; break }
    }
    if (!found) { return false }
    if (versions.length === 1) {
      this.deleteProject(projectId)
      return true
    }
    try {
      fs.unlinkSync(this.versionPath(projectId, versionId))
    } catch (e) {
      console.error('Delete version file failed: ' + (e as Error).message)
      throw e as Error
    }
    this.clearState(projectId, versionId)
    this.summaries.delete(projectId)
    return false
  }

  private metricNumber(obj: Record<string, Object>, key: string): number {
    let value = obj[key]
    return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : -1
  }

  private parseMetrics(raw: Object): VersionMetrics | null {
    if (raw === null || raw === undefined || typeof raw !== 'object' || Array.isArray(raw)) { return null }
    let obj = raw as Record<string, Object>
    let metrics = new VersionMetrics()
    metrics.provider = typeof obj['provider'] === 'string' ? obj['provider'] as string : ''
    metrics.model = typeof obj['model'] === 'string' ? obj['model'] as string : ''
    metrics.elapsedMs = this.metricNumber(obj, 'elapsedMs')
    metrics.runs = this.metricNumber(obj, 'runs')
    metrics.attempts = this.metricNumber(obj, 'attempts')
    metrics.inputTokens = this.metricNumber(obj, 'inputTokens')
    metrics.cacheHitTokens = this.metricNumber(obj, 'cacheHitTokens')
    metrics.outputTokens = this.metricNumber(obj, 'outputTokens')
    metrics.estimatedUsd = this.metricNumber(obj, 'estimatedUsd')
    metrics.partial = obj['partial'] !== false || metrics.elapsedMs < 0 || metrics.runs < 0 ||
      metrics.attempts < 0 || metrics.inputTokens < 0 || metrics.cacheHitTokens < 0 ||
      metrics.outputTokens < 0 || metrics.estimatedUsd < 0
    return metrics
  }

  private parseVersion(text: string): Version | null {
    try {
      let obj = JSON.parse(text) as Record<string, Object>
      // Parsing succeeded, but that only says the file is JSON -- not that it
      // is a version. A record with no id is some other file, and returning a
      // Version full of undefined fields hides that from every caller.
      let id = (obj['id'] as string) || ''
      if (id.length === 0) { return null }
      let v = new Version()
      v.id = id
      v.projectId = obj['projectId'] as string
      v.source = obj['source'] as string
      v.vbc2 = (obj['vbc2'] as string) || ''
      v.note = (obj['note'] as string) || ''
      // Versions saved before prompts were kept fall back to the truncated note.
      v.prompt = (obj['prompt'] as string) || v.note
      v.lastPrompt = (obj['lastPrompt'] as string) || v.prompt
      v.parentVersionId = (obj['parentVersionId'] as string) || ''
      v.origin = (obj['origin'] as string) || ''
      v.composition = (obj['composition'] as string) || ''
      v.metrics = this.parseMetrics(obj['metrics'])
      v.createdAt = obj['createdAt'] as number
      return v
    } catch (_e) { return null }
  }
}

export const store: ProjectStore = new ProjectStore()
