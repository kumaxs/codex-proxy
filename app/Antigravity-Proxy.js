ObjC.import('Foundation')

const shellRunner = Application.currentApplication()
shellRunner.includeStandardAdditions = true
const ui = Application.currentApplication()
ui.includeStandardAdditions = true

const homePath = ObjC.unwrap($.NSHomeDirectory())
const runtimeHome = homePath + '/Library/Application Support/Codex Proxy'
const launcherScript = runtimeHome + '/bin/launch-antigravity-proxied.sh'

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

function runShellScript(command) {
  return shellRunner.doShellScript(command)
}

function pathExists(path) {
  return runShellScript('/bin/test -e ' + shellQuote(path) + ' && echo 1 || echo 0') === '1'
}

function isSymlink(path) {
  return runShellScript('/bin/test -L ' + shellQuote(path) + ' && echo 1 || echo 0') === '1'
}

function showError(message) {
  ui.displayDialog(message, { buttons: ['OK'], defaultButton: 'OK', withTitle: 'Antigravity Proxy Error' })
}

function run() {
  try {
    if (!pathExists(launcherScript) || isSymlink(launcherScript)) {
      showError('The Antigravity proxy launcher is missing or invalid:\n' + launcherScript + '\n\nDeploy the current Codex Proxy project first.')
      return
    }
    const command = 'HOME=' + shellQuote(homePath) + ' CODEX_PROXY_HOME=' + shellQuote(runtimeHome) + ' /bin/zsh ' + shellQuote(launcherScript)
    runShellScript(command)
  } catch (err) {
    showError(String(err))
  }
}
