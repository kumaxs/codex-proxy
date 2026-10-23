ObjC.import('Foundation')

const shellRunner = Application.currentApplication()
const ui = shellRunner
ui.includeStandardAdditions = true

const runtimeHome = ObjC.unwrap($.NSHomeDirectory()) + '/Library/Application Support/Codex Proxy'
const configPath = runtimeHome + '/config/codex-proxy.conf'
const launcherScript = runtimeHome + '/bin/launch-codex-proxied.sh'
const rotateScript = runtimeHome + '/bin/rotate-launcher-log.sh'
const launcherBundleId = 'com.openai.codex'

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

function runShellScript(command) {
  return shellRunner.doShellScript(command)
}

function pathExists(path) {
  const testCommand = '[ -e ' + shellQuote(path) + ' ] && echo 1 || echo 0'
  return runShellScript('/bin/zsh -lc ' + shellQuote(testCommand)) === '1'
}

function isSymlink(path) {
  const testCommand = '[ -L ' + shellQuote(path) + ' ] && echo 1 || echo 0'
  return runShellScript('/bin/zsh -lc ' + shellQuote(testCommand)) === '1'
}

function runLauncherCommand(argv) {
  const commandParts = ['/bin/zsh', launcherScript]
  if (pathExists(configPath)) {
    commandParts.push('--config', configPath)
  }
  for (let i = 0; i < argv.length; i += 1) {
    commandParts.push(argv[i])
  }
  return runShellScript(commandParts.map(shellQuote).join(' '))
}

function trimValue(value) {
  return String(value).replace(/^\s+/, '').replace(/\s+$/, '')
}

function showMessage(message) {
  ui.displayDialog(message, { buttons: ['OK'], defaultButton: 'OK', withTitle: 'Codex Proxy' })
}

function showError(message) {
  ui.displayDialog(message, { buttons: ['OK'], defaultButton: 'OK', withTitle: 'Codex Proxy Error' })
}

function confirmDangerous(message) {
  try {
    const response = ui.displayDialog(message, {
      buttons: ['Cancel', 'Proceed'],
      defaultButton: 'Cancel',
      cancelButton: 'Cancel',
      withTitle: 'Codex Proxy',
    })
    return response.buttonReturned === 'Proceed'
  } catch (err) {
    if (err && (err.errorNumber === -128 || err.number === -128)) {
      return false
    }
    throw err
  }
}

function resolveAction(argv) {
  // JXA applets may pass a plain object for Finder launches rather than an
  // actual JavaScript array. Normalize that to the no-argument click path.
  const args = Array.isArray(argv) ? argv : []
  if (args.length === 0) {
    return 'launch'
  }
  const first = String(args[0]).toLowerCase()
  if (first === 'launch' || first === '--launch' || first === '--launch-and-verify' || first === 'start') {
    return 'launch'
  }
  if (first === '--status' || first === 'status') {
    return 'status'
  }
  if (first === '--preflight' || first === 'preflight') {
    return 'preflight'
  }
  if (first === '--verify-current' || first === 'verify') {
    return 'verify'
  }
  if (first === '--terminate-residuals' || first === '--term' || first === 'terminate') {
    return 'terminate'
  }
  if (first === '--rotate-log' || first === 'rotate') {
    return 'rotate'
  }
  if (first === '--help' || first === 'help') {
    return 'help'
  }
  // Finder/LaunchServices can supply an invocation argument that is not one
  // of our documented actions. Treat those as a normal click, not the help UI.
  return 'launch'
}

function getProcessState() {
  const state = trimValue(runLauncherCommand(['--process-state']))
  if (state !== 'present' && state !== 'absent') {
    throw new Error('Launcher process-state is unavailable: ' + state)
  }
  return state
}

function quitChatGPTGracefully() {
  const app = Application(launcherBundleId)
  if (app.running()) {
    app.quit()
  }
}

function performLaunch() {
  let state

  state = getProcessState()
  if (state === 'present') {
    if (!confirmDangerous('Codex is running. Attempt graceful quit via Application(\'com.openai.codex\').quit()?')) {
      return
    }
    quitChatGPTGracefully()
    try {
      runLauncherCommand(['--wait-clear'])
    } catch (err) {
      if (getProcessState() !== 'present') {
        throw err
      }
    }
    if (getProcessState() === 'present') {
      if (!confirmDangerous('Graceful quit did not clear residual processes. Send TERM to remaining processes?')) {
        return
      }
      if (!confirmDangerous('Second confirmation: confirm TERM is still needed.')) {
        return
      }
      runLauncherCommand(['--terminate-residuals', '--confirmed-by-user'])
      if (getProcessState() !== 'absent') {
        throw new Error('Residual Codex processes remain after TERM.')
      }
    }
  }

  return runLauncherCommand(['--launch-and-verify'])
}

function launchAction(argv) {
  return runLauncherCommand(argv)
}

function executeAction(action) {
  try {
    if (action === 'launch') {
      // Do not display launcher stdout as a modal success dialog. On a normal
      // click, start/verify the proxied app and bring ChatGPT directly forward.
      // If a restart confirmation was canceled, still foreground existing ChatGPT.
      performLaunch()
      try {
        Application(launcherBundleId).activate()
      } catch (e) {
        // activate is best-effort only.
      }
      return
    }
    if (action === 'status') {
      showMessage(runLauncherCommand(['--status']))
      return
    }
    if (action === 'preflight') {
      showMessage(runLauncherCommand(['--preflight']))
      return
    }
    if (action === 'verify') {
      showMessage(runLauncherCommand(['--verify-current']))
      return
    }
    if (action === 'rotate') {
      if (!pathExists(rotateScript) || isSymlink(rotateScript)) {
        showError('Missing or invalid rotate script: ' + rotateScript)
        return
      }
      runShellScript('/bin/zsh ' + shellQuote(rotateScript))
      showMessage('Launcher log has been rotated.')
      return
    }
    if (action === 'terminate') {
      if (!confirmDangerous('Terminate all matching Codex Proxy ChatGPT processes now?')) {
        return
      }
      if (!confirmDangerous('Second confirmation: confirm TERM is still needed.')) {
        return
      }
      launchAction(['--terminate-residuals', '--confirmed-by-user'])
      showMessage('TERM was dispatched for matching processes.')
      return
    }
    showMessage('Codex Proxy actions:\nlaunch (default)\nstatus\npreflight\nverify\nterminate\nrotate')
  } catch (err) {
    showError(String(err))
  }
}

function run(argv) {
  if (!pathExists(launcherScript) || isSymlink(launcherScript)) {
    showError('Launcher helper is missing or invalid: ' + launcherScript)
    return
  }
  if (pathExists(runtimeHome) && isSymlink(runtimeHome)) {
    showError('Runtime home path is invalid (symlink not allowed): ' + runtimeHome)
    return
  }
  executeAction(resolveAction(argv))
}
