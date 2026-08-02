#!/usr/bin/env node

// Direct standalone ghostty-vt.wasm ABI smoke. No wasm-bindgen, Cargo, WASI,
// callbacks, or host file descriptors are involved.
import { readFile } from "node:fs/promises";
import assert from "node:assert/strict";

const wasmPath = process.argv[2] ?? "zig-out/bin/ghostty-vt.wasm";
const wasmBytes = await readFile(wasmPath);
const module = await WebAssembly.compile(wasmBytes);
const imports = {};
for (const entry of WebAssembly.Module.imports(module)) {
  imports[entry.module] ??= {};
  if (entry.kind === "function") imports[entry.module][entry.name] = () => 0;
  else if (entry.kind === "memory") {
    imports[entry.module][entry.name] = new WebAssembly.Memory({ initial: 32 });
  } else if (entry.kind === "table") {
    imports[entry.module][entry.name] = new WebAssembly.Table({
      initial: 0,
      element: "anyfunc",
    });
  } else if (entry.kind === "global") {
    imports[entry.module][entry.name] = new WebAssembly.Global({
      value: "i32",
      mutable: true,
    }, 0);
  }
}
const { exports: e } = await WebAssembly.instantiate(module, imports);
assert.ok(e.memory instanceof WebAssembly.Memory);

const u8 = () => new Uint8Array(e.memory.buffer);
const view = () => new DataView(e.memory.buffer);
const alloc = (len) => {
  const ptr = e.ghostty_alloc(0, len);
  assert.notEqual(ptr, 0, `allocation failed (${len} bytes)`);
  return ptr;
};
const free = (ptr, len) => e.ghostty_free(0, ptr, len);
const cString = (ptr) => {
  const memory = u8();
  let end = ptr;
  while (memory[end] !== 0) ++end;
  return new TextDecoder().decode(memory.subarray(ptr, end));
};
const layouts = JSON.parse(cString(e.ghostty_type_json()));
const layout = (name) => {
  const value = layouts[name];
  assert.ok(value, `missing ${name} from ghostty_type_json`);
  return value;
};
const field = (name, member) => layout(name).fields[member].offset;
const struct = (name) => {
  const size = layout(name).size;
  const ptr = alloc(size);
  u8().fill(0, ptr, ptr + size);
  view().setUint32(ptr + field(name, "size"), size, true);
  if (layout(name).fields.version)
    view().setUint32(ptr + field(name, "version"), 1, true);
  return { ptr, size, name };
};
const dispose = (s) => free(s.ptr, s.size);
const getUsize = (s, member) => view().getUint32(
  s.ptr + field(s.name, member), true);
const setUsize = (s, member, value) => view().setUint32(
  s.ptr + field(s.name, member), value, true);
const getI32 = (s, member) => view().getInt32(
  s.ptr + field(s.name, member), true);

const SUCCESS = 0;
const UNKNOWN_VERSION = -2;
const OUT_OF_SPACE = -13;
const CAPTURE_READY = 1;
const CAPTURE_FINISH = 4;
const DECODE_READY = 2;
const DECODE_FINISH = 5;

const terminalSlot = alloc(4);
view().setUint32(terminalSlot, 0, true);
assert.equal(e.ghostty_terminal_new(0, terminalSlot, 40, 8), 0);
const source = view().getUint32(terminalSlot, true);
assert.notEqual(source, 0);
const text = new TextEncoder().encode("wasm-ready\r\n".repeat(40));
const textPtr = alloc(text.length);
u8().set(text, textPtr);
e.ghostty_terminal_vt_write(source, textPtr, text.length);
free(textPtr, text.length);

const capabilities = struct("GhosttyTerminalSnapshotIncrementalCapabilities");
assert.equal(e.ghostty_terminal_snapshot_incremental_capabilities(
  capabilities.ptr), SUCCESS);
assert.equal(view().getUint8(
  capabilities.ptr + field(capabilities.name, "incremental")), 1);
dispose(capabilities);

const captureOptions = struct("GhosttyTerminalSnapshotCaptureOptions");
setUsize(captureOptions, "max_record_bytes", 4 * 1024 * 1024);
setUsize(captureOptions, "max_pages", 4096);
const captureSlot = alloc(4);
view().setUint32(captureSlot, 0, true);
assert.equal(e.ghostty_terminal_snapshot_capture_new(
  0, source, captureOptions.ptr, captureSlot), SUCCESS);
const capture = view().getUint32(captureSlot, true);
assert.notEqual(capture, 0);

const records = [];
let sawReady = false;
for (;;) {
  const event = struct("GhosttyTerminalSnapshotCaptureEvent");
  assert.equal(e.ghostty_terminal_snapshot_capture_next(
    capture, 0, 0, event.ptr), OUT_OF_SPACE);
  const required = getUsize(event, "required_bytes");
  assert.ok(required > 0);
  const record = alloc(required);
  assert.equal(e.ghostty_terminal_snapshot_capture_next(
    capture, record, required, event.ptr), SUCCESS);
  const written = getUsize(event, "written");
  assert.equal(written, required);
  records.push(Uint8Array.from(u8().subarray(record, record + written)));
  const kind = getI32(event, "kind");
  if (kind === CAPTURE_READY) sawReady = true;
  free(record, required);
  dispose(event);
  if (kind === CAPTURE_FINISH) break;
}
assert.ok(sawReady);
e.ghostty_terminal_snapshot_capture_free(capture);
free(captureSlot, 4);
dispose(captureOptions);

const encodedLength = records.reduce((n, record) => n + record.length, 0);
const encoded = new Uint8Array(encodedLength);
let writeOffset = 0;
for (const record of records) {
  encoded.set(record, writeOffset);
  writeOffset += record.length;
}
const encodedPtr = alloc(encoded.length);
u8().set(encoded, encodedPtr);

const decoderOptions = struct("GhosttyTerminalSnapshotDecoderOptions");
setUsize(decoderOptions, "max_continuation_bytes", 1024 * 1024);
setUsize(decoderOptions, "max_record_bytes", 4 * 1024 * 1024);
setUsize(decoderOptions, "max_pages", 4096);
const decoderSlot = alloc(4);
view().setUint32(decoderSlot, 0, true);
assert.equal(e.ghostty_terminal_snapshot_decoder_new(
  0, decoderOptions.ptr, decoderSlot), SUCCESS);
const decoder = view().getUint32(decoderSlot, true);
let decodedTerminal = 0;
let offset = 0;
while (offset < encoded.length) {
  const event = struct("GhosttyTerminalSnapshotDecodeEvent");
  assert.equal(e.ghostty_terminal_snapshot_decoder_push(
    decoder, encodedPtr + offset, 1, event.ptr), SUCCESS);
  const consumed = getUsize(event, "consumed");
  assert.equal(consumed, 1);
  offset += consumed;
  const kind = getI32(event, "kind");
  if (kind === DECODE_READY) {
    const take = struct("GhosttyTerminalSnapshotTakeTerminalResult");
    assert.equal(e.ghostty_terminal_snapshot_decoder_take_terminal(
      decoder, take.ptr), SUCCESS);
    decodedTerminal = view().getUint32(
      take.ptr + field(take.name, "terminal"), true);
    assert.notEqual(decodedTerminal, 0);
    assert.equal(e.ghostty_terminal_snapshot_decoder_replay_continuation(
      decoder, decodedTerminal), SUCCESS);
    dispose(take);
  }
  dispose(event);
  if (kind === DECODE_FINISH) break;
}
assert.equal(offset, encoded.length);
assert.notEqual(decodedTerminal, 0);
e.ghostty_terminal_snapshot_decoder_free(decoder);

// Unknown version maps to a structured error and never traps.
const damaged = Uint8Array.from(encoded);
damaged[8] = 0xff;
damaged[9] = 0x7f;
u8().set(damaged, encodedPtr);
view().setUint32(decoderSlot, 0, true);
assert.equal(e.ghostty_terminal_snapshot_decoder_new(
  0, decoderOptions.ptr, decoderSlot), SUCCESS);
const badDecoder = view().getUint32(decoderSlot, true);
const badEvent = struct("GhosttyTerminalSnapshotDecodeEvent");
assert.equal(e.ghostty_terminal_snapshot_decoder_push(
  badDecoder, encodedPtr, damaged.length, badEvent.ptr), UNKNOWN_VERSION);
e.ghostty_terminal_snapshot_decoder_free(badDecoder);
dispose(badEvent);

e.ghostty_terminal_free(decodedTerminal);
e.ghostty_terminal_free(source);
free(encodedPtr, encoded.length);
free(decoderSlot, 4);
free(terminalSlot, 4);
dispose(decoderOptions);
console.log("standalone incremental snapshot wasm smoke: ok");
