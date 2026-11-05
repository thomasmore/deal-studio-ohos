export class AppRouteParams {
  projectId: string = ''
  versionId: string = ''
  vbc2: string = ''
  shortcutMode: string = ''
  launchError: string = ''
  baseVersionId: string = ''
  chatId: string = ''
  prompt: string = ''
  run: string = ''
  fromList: string = ''
}

export class AppNavigationSession {
  pathStack: NavPathStack | null = null
  onReady: () => void = (): void => {}
  private active: boolean = true

  attach(pathStack: NavPathStack): void {
    if (!this.active) { return }
    this.pathStack = pathStack
    this.onReady()
  }

  detach(pathStack: NavPathStack): void {
    if (this.pathStack !== pathStack) { return }
    this.pathStack = null
  }

  invalidate(): void {
    this.active = false
    this.pathStack = null
    this.onReady = (): void => {}
  }
}

export function returnToLibrary(pathStack: NavPathStack): void {
  // Return to the root without duplicating navigation entries.
  const index = pathStack.getAllPathName().indexOf('library');
  if (index >= 0) {
    pathStack.popToName('library')
  } else if (pathStack.size() > 0) {
    // Reset to the library only when the stack is not empty.
    pathStack.clear(false)
    pathStack.pushPath({ name: 'library', param: new AppRouteParams() }, false)
  }
}
