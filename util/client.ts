import { Position } from 'vscode-languageserver-types'
import { spawn } from 'child_process'

interface InitializeParams {
	/**
	 * The process Id of the parent process that started
	 * the server. Is null if the process has not been started by another process.
	 * If the parent process is not alive then the server should exit (see exit notification) its process.
	 */
	processId?: number;

	/**
	 * The rootPath of the workspace. Is null
	 * if no folder is open.
	 */
	rootPath?: string;

	/**
	 * User provided initialization options.
	 */
	initializationOptions?: any;

	/**
	 * The capabilities provided by the client (editor)
	 */
	capabilities: ClientCapabilities;
}

interface ClientCapabilities {
}

const ls = spawn('../build/vala-language-server', [], {
  env: {
    G_MESSAGES_DEBUG: 'all',
    JSONRPC_DEBUG: 1
  }
})

ls.stdout.on('data', (data) => {
  console.log(`<<< ${data}`)
})

let id = 1
function makeMessage(method: string, params: object) {
  const json = JSON.stringify({
    jsonrpc: "2.0",
    method,
    params,
    id: id++
  })

  const out = `Content-Length: ${json.length}\n\n${json}`

  console.log(`>>> ${json}`)
  return out
}

ls.on('close', (code) => {
  console.log('vala language server ended')
})

const init: InitializeParams = {
  processId: process.pid,
  rootPath: "/home/ben/test.vala",
  initializationOptions: null,
  capabilities: {},
}

ls.stdin.write(makeMessage("initialize", init), null)
