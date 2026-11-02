import { bundleManager, shortcutManager, common } from '@kit.AbilityKit'
import { osAccount, BusinessError } from '@kit.BasicServicesKit'
import { projectShortcutIconResource } from './ProjectIcons'
import { Project, ProjectStore, Version, store } from './ProjectStore'
import { rpc } from '@kit.IPCKit'
import { process, util } from '@kit.ArkTS'

/*
 * A project's icon on the home screen.
 *
 * shortcutManager.addDesktopShortcutInfo only writes BMS's record of what the launcher shows; the launcher never reads
 * a record it did not write, so nothing appears. Dynamic shortcuts appear only in the long-press menu of VERA's icon.
 * What does put an icon on the desktop is the launcher's own service: SceneBoard's DesktopProviderService, request
 * code 7 (desktopIcon), method addShortcutToDesktop with a shortcut given in full (sourceType 0, the launcher's
 * CUSTOM_TYPE) and the picture as base64 PNG in foregroundIcon. It needs GET_BUNDLE_INFO_PRIVILEGED, which this app
 * holds. The interface is private to this SceneBoard (found in its bytecode on ALN-AL80, Oct 2026): a launcher update
 * may change it, so every call checks the result by reading back BMS's record, which the launcher writes on success.
 */

const LAUNCHER_BUNDLE = 'com.ohos.sceneboard'
const LAUNCHER_SERVICE = 'DesktopProviderService'
const LAUNCHER_DESKTOP_ICON = 7
const LAUNCHER_CUSTOM_SHORTCUT = 0
// The launcher reads a count, then that many strings of at most 480 characters, and joins them (BaseServiceStubUtils).
const SEGMENT = 512
const MAX_SEGMENTS = 32

/** The launcher answers through this object; nothing here depends on the answer, which is checked in BMS instead. */
class LauncherCallback extends rpc.RemoteObject {
  constructor() { super('VeraShortcutCallback') }
  onRemoteMessageRequest(code: number, _data: rpc.MessageSequence, _reply: rpc.MessageSequence,
      _options: rpc.MessageOption): boolean {
    console.info('VERA-SHORTCUT launcher answered code = ' + code.toString())
    return true
  }
}

function callLauncher(context: common.UIAbilityContext, method: string, extra: Object): Promise<void> {
  let message: Record<string, Object> = {}
  message['method'] = method
  message['extra'] = extra
  let text = JSON.stringify(message)
  let parts: string[] = []

  for (let i = 0; i < text.length; i += SEGMENT) {
    parts.push(text.substring(i, i + SEGMENT))
  }

  if (parts.length > MAX_SEGMENTS) {
    return Promise.reject(new Error(`Shortcut payload length ${text.length} too long: generated segments: ${parts.length}, max allowed: ${MAX_SEGMENTS}`))
  }

  return new Promise<void>((resolve, reject): void => {
    let connection = -1
    let settled = false
    let timeout = -1

    let finish = (error: Error | null): void => {
      if (settled) { return }
      settled = true
      clearTimeout(timeout)

      // Give the launcher time to use the callback before disconnecting
      setTimeout((): void => {
        if (connection < 0) { return }
        try {
          context.disconnectServiceExtensionAbility(connection)
            .catch((err: Object) => { console.error(`Disconnect failed: ${err instanceof Error ? err.message : JSON.stringify(err)}`) })
        } catch (e) {
          console.error('Disconnect failed: ' + (e as Error).message)
        }
      }, 2000)

      if (error !== null) { reject(error) } else { resolve() }
    }

    timeout = setTimeout((): void => { finish(new Error('Launcher did not answer')) }, 10000)
    try {
      connection = context.connectServiceExtensionAbility({
        bundleName: LAUNCHER_BUNDLE,
        abilityName: LAUNCHER_SERVICE
      }, {
        onConnect: (_element, remote: rpc.IRemoteObject): void => {
          if (settled) { return }
          let data = rpc.MessageSequence.create()
          let reply = rpc.MessageSequence.create()

          try {
            data.writeInt(parts.length)
            for (let part of parts) { data.writeString(part) }
            data.writeRemoteObject(new LauncherCallback())

            // Explicitly set asynchronous IPC mode (TF_ASYNC = 1)
            let option = new rpc.MessageOption(rpc.MessageOption.TF_ASYNC)

            remote.sendMessageRequest(LAUNCHER_DESKTOP_ICON, data, reply, option)
              .then((r: rpc.RequestResult): void => {
                // Reclaim memory STRICTLY after the response completes!
                data.reclaim()
                reply.reclaim()
                finish(r.errCode === 0 ? null : new Error('launcher request failed, errCode ' + r.errCode.toString()))
              })
              .catch((e: Object): void => {
                data.reclaim()
                reply.reclaim()
                finish(new Error('launcher request failed, ' + (e instanceof Error ? e.message : JSON.stringify(e))))
              })
          } catch (err) {
            data.reclaim()
            reply.reclaim()
            finish(new Error('IPC parceling failed: ' + (err instanceof Error ? err.message : JSON.stringify(err))))
          }
        },
        onDisconnect: (): void => { finish(new Error('launcher disconnected')) },
        onFailed: (code: number): void => { finish(new Error('cannot reach the launcher, code ' + code.toString())) }
      })
    } catch (e) {
      finish(e as Error)
    }
  })
}

function selfUserId(): number {
  try {
    return osAccount.getAccountManager().getOsAccountLocalIdForUidSync(process.uid)
  } catch (e) {
    throw e as Error
  }
}

async function desktopContains(id: string, bundleName: string): Promise<boolean> {
  try {
    let all: shortcutManager.ShortcutInfo[] = await shortcutManager.getAllDesktopShortcutInfo(selfUserId())
    return all.some((s: shortcutManager.ShortcutInfo): boolean => s.id === id && s.bundleName === bundleName)
  } catch (e) {
    throw e as Error
  }
}

/** Whether BMS's record of this shortcut is as expected, waiting up to ~5.6 s for the launcher to write it. */
async function desktopHas(id: string, bundleName: string, expected: boolean): Promise<boolean> {
  for (let i = 1; i <= 7; i++) {
    let found = await desktopContains(id, bundleName)
    if (found === expected) { return true }
    await new Promise<void>((resolve): void => { setTimeout(resolve, i * 200) })
  }
  return await desktopContains(id, bundleName) === expected
}

export enum ProjectShortcutState {
  Unknown,
  Present,
  Absent,
  Failed
}

export enum ProjectOperationStatus {
  Success,
  ProjectDeleted,
  NotFound,
  Failed,
  Busy,
  ProjectDeletedShortcutRemovalFailed
}

export class ProjectOperations {
  private projectStore: ProjectStore
  private operationLocks: Set<string> = new Set<string>()
  private cachedSelfBundleName: string | null = null

  constructor(projectStore: ProjectStore) {
    this.projectStore = projectStore
  }

  public async getShortcutState(id: string): Promise<ProjectShortcutState> {
    try {
      if (this.projectStore.getProject(id) === null) {
        this.notFound(id)
        return ProjectShortcutState.Failed
      }
      const present = await desktopContains(this.shortcutId(id), this.selfBundleName())
      if (this.projectStore.getProject(id) === null) {
        this.notFound(id)
        return ProjectShortcutState.Failed
      }
      return present ? ProjectShortcutState.Present : ProjectShortcutState.Absent
    } catch (e) {
      this.logFailure('Get project shortcut state', id, e)
      return ProjectShortcutState.Failed
    }
  }

  public async pinProject(context: common.UIAbilityContext | (() => common.UIAbilityContext), id: string): Promise<ProjectOperationStatus> {
    return this.runOperation(id, 'Add project shortcut', async (): Promise<ProjectOperationStatus> => {
      let project = this.projectStore.getProject(id)
      if (project === null) { return this.notFound(id) }
      const bundleName = this.selfBundleName()
      const present = await desktopContains(this.shortcutId(id), bundleName)
      project = this.projectStore.getProject(id)
      if (project === null) { return this.notFound(id) }
      if (present) { return ProjectOperationStatus.Success }

      const resolvedContext = this.resolveContext(context)
      await callLauncher(resolvedContext, 'addShortcutToDesktop', this.shortcutFor(resolvedContext, project))
      if (this.projectStore.getProject(id) === null) { return this.notFound(id) }
      if (!await desktopHas(this.shortcutId(id), bundleName, true)) { throw new Error('Add shortcut') }
      if (this.projectStore.getProject(id) === null) { return this.notFound(id) }
      console.info(`Shortcut "${this.shortcutId(id)}" was added successfully`);

      return ProjectOperationStatus.Success
    })
  }

  public async unpinProject(context: common.UIAbilityContext | (() => common.UIAbilityContext), id: string): Promise<ProjectOperationStatus> {
    return this.runOperation(id, 'Remove project shortcut', async (): Promise<ProjectOperationStatus> => {
      return await this.unpinProjectInternal(context, id)
    })
  }

  /**
   * Brings the home-screen shortcut's label in line with the project's current name.
   */
  public async renameShortcut(context: common.UIAbilityContext | (() => common.UIAbilityContext),
      id: string): Promise<ProjectOperationStatus> {
    return this.runOperation(id, 'Rename project shortcut', async (): Promise<ProjectOperationStatus> => {
      const project = this.projectStore.getProject(id)   // fresh from DB, with the new name
      if (project === null) { return this.notFound(id) }
      const bundleName = this.selfBundleName()
      const present = await desktopContains(this.shortcutId(id), bundleName)
      if (this.projectStore.getProject(id) === null) { return this.notFound(id) }
      if (!present) { return ProjectOperationStatus.Success }  // nothing to rename

      const resolvedContext = this.resolveContext(context)

      // Reliable path: remove existing shortcut and re-create with the new name.
      const unpin = await this.unpinProjectInternal(context, id)
      if (unpin !== ProjectOperationStatus.Success) { return unpin }
      if (this.projectStore.getProject(id) === null) { return this.notFound(id) }
      await callLauncher(resolvedContext, 'addShortcutToDesktop',
        this.shortcutFor(resolvedContext, project))
      if (this.projectStore.getProject(id) === null) { return this.notFound(id) }
      if (!await desktopHas(this.shortcutId(id), bundleName, true)) {
        throw new Error('Add renamed shortcut')
      }
      console.info('VERA-SHORTCUT re-added with new name: ' + id)
      return ProjectOperationStatus.Success
    })
  }

  public async deleteProject(context: common.UIAbilityContext | (() => common.UIAbilityContext), id: string): Promise<ProjectOperationStatus> {
    return this.runOperation(id, 'Delete project', async (): Promise<ProjectOperationStatus> => {
      const project = this.projectStore.getProject(id)
      if (project === null) { return this.notFound(id) }
      const status = await this.unpinProjectInternal(context, id)
      if (this.projectStore.getProject(id) === null) { return this.notFound(id) }
      this.projectStore.deleteProject(id)
      return status === ProjectOperationStatus.Success ? ProjectOperationStatus.Success :
        ProjectOperationStatus.ProjectDeletedShortcutRemovalFailed
    })
  }

  public async deleteVersion(context: common.UIAbilityContext | (() => common.UIAbilityContext), id: string, versionId: string): Promise<ProjectOperationStatus> {
    return this.runOperation(id, 'Delete Version ' + versionId, async (): Promise<ProjectOperationStatus> => {
      const project = this.projectStore.getProject(id)
      if (project === null) { return this.notFound(id, versionId) }
      let versions = this.projectStore.listVersions(id)
      if (!versions.some((version: Version) => version.id === versionId)) {
        return this.notFound(id, versionId)
      }
      let shortcutRemovalFailed = false
      if (versions.length === 1) {
        const status = await this.unpinProjectInternal(context, id)
        shortcutRemovalFailed = status !== ProjectOperationStatus.Success
      }
      if (this.projectStore.getProject(id) === null) {
        return this.notFound(id, versionId)
      }
      versions = this.projectStore.listVersions(id)
      if (!versions.some((version: Version) => version.id === versionId)) {
        return this.notFound(id, versionId)
      }
      const deletedProject = this.projectStore.deleteVersion(id, versionId)
      if (deletedProject && shortcutRemovalFailed) {
        return ProjectOperationStatus.ProjectDeletedShortcutRemovalFailed
      }
      return deletedProject ? ProjectOperationStatus.ProjectDeleted : ProjectOperationStatus.Success
    })
  }

  private resolveContext(context: common.UIAbilityContext | (() => common.UIAbilityContext)): common.UIAbilityContext {
    const resolvedContext = typeof context === 'function' ? context() : context
    if (resolvedContext === null || resolvedContext === undefined) {
      throw new Error('UIAbilityContext is unavailable: cannot access the launcher.')
    }
    return resolvedContext
  }

  private shortcutId(projectId: string): string {
    return `vera_project_${projectId}`
  }

  private selfBundleName(): string {
    if (this.cachedSelfBundleName === null) {
      this.cachedSelfBundleName = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).name
    }
    return this.cachedSelfBundleName
  }

  private deletion(id: string): Record<string, Object>[] {
    let item: Record<string, Object> = {}
    item['bundleName'] = this.selfBundleName()
    item['id'] = this.shortcutId(id)
    item['appIndex'] = 0
    return [item]
  }

  private shortcutFor(context: common.UIAbilityContext, project: Project): Record<string, Object> {
    let bundleName = this.selfBundleName()
    let icon = projectShortcutIconResource(project.icon)
    let projectParam: Record<string, Object> = {}
    projectParam['key'] = 'projectId'
    projectParam['value'] = project.id
    let modeParam: Record<string, Object> = {}
    modeParam['key'] = 'launchMode'
    modeParam['value'] = 'runLatest'
    let want: Record<string, Object> = {}
    want['targetBundle'] = bundleName
    want['targetModule'] = 'entry'
    want['targetAbility'] = 'EntryAbility'
    want['parameters'] = [projectParam, modeParam]
    let info: Record<string, Object> = {}
    info['id'] = this.shortcutId(project.id)
    info['bundleName'] = bundleName
    info['moduleName'] = 'entry'
    info['hostAbility'] = 'EntryAbility'
    info['appIndex'] = 0
    info['sourceType'] = LAUNCHER_CUSTOM_SHORTCUT
    info['label'] = project.name
    info['labelId'] = 0
    info['iconId'] = icon.id
    info['visible'] = true
    info['wants'] = [want]
    // The launcher takes the picture from foregroundIcon (it overwrites icon with it), as base64 PNG.
    try {
      info['foregroundIcon'] = new util.Base64Helper().encodeToStringSync(context.resourceManager.getMediaContentSync(icon.id))
    } catch (e) {
      throw e as Error
    }
    return info
  }

  private async unpinProjectInternal(context: common.UIAbilityContext | (() => common.UIAbilityContext), id: string): Promise<ProjectOperationStatus> {
    try {
      if (this.projectStore.getProject(id) === null) { return this.notFound(id) }
      const bundleName = this.selfBundleName()
      const present = await desktopContains(this.shortcutId(id), bundleName)
      if (this.projectStore.getProject(id) === null) { return this.notFound(id) }
      if (!present) { return ProjectOperationStatus.Success }

      await callLauncher(this.resolveContext(context), 'deleteDesktopShortcut', this.deletion(id))
      if (this.projectStore.getProject(id) === null) { return this.notFound(id) }
      if (!await desktopHas(this.shortcutId(id), bundleName, false)) {
        throw new Error('the launcher did not remove the icon')
      }
      if (this.projectStore.getProject(id) === null) { return this.notFound(id) }
      console.info(`Shortcut "${this.shortcutId(id)}" was deleted successfully`);

      return ProjectOperationStatus.Success
    } catch (e) {
      this.logFailure("Remove project shortcut", id, e)
      return ProjectOperationStatus.Failed
    }
  }

  private async runOperation(id: string, operation: string,
      action: () => Promise<ProjectOperationStatus>): Promise<ProjectOperationStatus> {
    let locked = false
    try {
      if (this.operationLocks.has(id)) {
        console.warn('Project operation "' + operation + '" for project "' + id + '" is busy')
        return ProjectOperationStatus.Busy
      }
      this.operationLocks.add(id)
      locked = true
      return await action()
    } catch (e) {
      this.logFailure(operation, id, e)
      return ProjectOperationStatus.Failed
    } finally {
      if (locked) { this.operationLocks.delete(id) }
    }
  }

  private notFound(id: string, versionId: string = ''): ProjectOperationStatus {
    console.warn('Project not found for id "' + id +
      (versionId.length > 0 ? '" version = ' + versionId : '"'))
    return ProjectOperationStatus.NotFound
  }

  private logFailure(operation: string, id: string, error: Object): void {
    try {
      let code = 'unknown'
      let message = 'Unknown error'
      if (error !== null && error !== undefined) {
        if (typeof error === 'object') {
          const businessError = error as BusinessError
          if (businessError.code !== undefined) { code = String(businessError.code) }
          message = typeof businessError.message === 'string' ? businessError.message : String(error)
        } else {
          message = String(error)
        }
      }
      console.error(operation + ' failed for project "' + id +
        '": error code = ' + code + ', message = "' + message + '"')
    } catch (_e) {
      try {
        console.error(operation + ' failed for project "' + id +
          '": error code = unknown, message = "Unable to format error"')
      } catch (_loggingError) {}
    }
  }
}

export const projectOperations: ProjectOperations = new ProjectOperations(store)
