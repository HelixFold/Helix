// Runs a WASI program with Node's built-in WASI: node e2e/wasi-run.mjs program.wasm [args...]
// The current folder is preopened as `.`, and the environment is passed through.
import { readFileSync } from 'node:fs';
import process from 'node:process';
import { WASI } from 'node:wasi';

const wasi = new WASI({ version: 'preview1', args: process.argv.slice(2), env: process.env, preopens: { '.': '.' }, returnOnExit: true });
const module = await WebAssembly.compile(readFileSync(process.argv[2]));
const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport });   // Node 18 too
process.exit(wasi.start(instance));
