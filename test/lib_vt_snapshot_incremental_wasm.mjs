#!/usr/bin/env node

// Direct standalone ghostty-vt.wasm ABI smoke. Browser consumers, including
// phux-web, should instantiate this artifact through JS (or wasm-bindgen JS
// glue) and provide the import below. Cargo wasm must not try to link the
// native libghostty-rs archive into its wasm module.
import { readFile } from "node:fs/promises";
import { webcrypto } from "node:crypto";
import assert from "node:assert/strict";

const wasmPath = process.argv[2] ?? "zig-out/bin/ghostty-vt.wasm";
const wasmBytes = await readFile(wasmPath);
const module = await WebAssembly.compile(wasmBytes);
const moduleImports = WebAssembly.Module.imports(module);
const entropyImport = {
  module: "ghostty",
  name: "host_entropy_fill",
  kind: "function",
};
assert.deepEqual(
  moduleImports.filter((entry) => entry.module === entropyImport.module),
  [entropyImport],
  "standalone wasm must require exactly ghostty.host_entropy_fill",
);
for (const entry of moduleImports) {
  assert.ok(
    entry.module === "ghostty" ||
      (entry.module === "env" &&
        entry.name === "log" &&
        entry.kind === "function"),
    `unexpected standalone wasm import ${entry.module}.${entry.name}:${entry.kind}`,
  );
}

// `getRandomValues` is shared by Node's Web Crypto and browsers. Reacquire a
// view for every chunk so a prior wasm memory growth can never leave this host
// writing into a detached ArrayBuffer. Exceptions become a nonzero import
// result; there is deliberately no zero-filled or predictable fallback.
function secureEntropy(getMemory, ptr, len) {
  try {
    const memory = getMemory();
    if (!(memory instanceof WebAssembly.Memory)) return -1;
    const end = ptr + len;
    if (!Number.isSafeInteger(end) || end > memory.buffer.byteLength) return -1;
    for (let offset = 0; offset < len; offset += 65536) {
      const count = Math.min(65536, len - offset);
      webcrypto.getRandomValues(
        new Uint8Array(memory.buffer, ptr + offset, count),
      );
    }
    return 0;
  } catch {
    return -1;
  }
}

async function instantiateRuntime(entropyProvider = secureEntropy) {
  let memory = null;
  const imports = {};
  for (const entry of moduleImports) {
    imports[entry.module] ??= {};
    if (
      entry.module === entropyImport.module &&
      entry.name === entropyImport.name
    ) {
      imports[entry.module][entry.name] = (ptr, len) => {
        try {
          return entropyProvider(() => memory, ptr >>> 0, len >>> 0) | 0;
        } catch {
          return -1;
        }
      };
    } else if (entry.module === "env" && entry.name === "log") {
      imports.env.log = () => {};
    }
  }
  const instance = await WebAssembly.instantiate(module, imports);
  memory = instance.exports.memory;
  assert.ok(memory instanceof WebAssembly.Memory);
  return new Runtime(instance.exports);
}

const SUCCESS = 0;
const RESULT_OUT_OF_SPACE = -3;
const UNSUPPORTED_FEATURE = -1;
const UNKNOWN_VERSION = -2;
const CORRUPTION = -3;
const LIMIT_EXCEEDED = -5;
const WRONG_GENERATION = -8;
const WRONG_TERMINAL = -9;
const INVALID_HANDLE = -10;
const IMPORT_BUSY = -11;
const OUT_OF_MEMORY = -12;
const OUT_OF_SPACE = -13;
const INVALID_STATE = -14;
const ENTROPY_UNAVAILABLE = -18;
const CAPTURE_RECORD = 0;
const CAPTURE_READY = 1;
const CAPTURE_HISTORY_BEGIN = 2;
const CAPTURE_HISTORY_PAGE = 3;
const CAPTURE_FINISH = 4;
const DECODE_READY = 2;
const DECODE_HISTORY_BEGIN = 3;
const DECODE_HISTORY_PAGE = 4;
const DECODE_FINISH = 5;
const HISTORY_UNIT = 0;
const HISTORY_END = 1;

class Runtime {
  constructor(exports) {
    this.e = exports;
    this.layouts = JSON.parse(this.cString(exports.ghostty_type_json()));
  }

  u8() {
    return new Uint8Array(this.e.memory.buffer);
  }
  view() {
    return new DataView(this.e.memory.buffer);
  }

  alloc(len) {
    const ptr = this.e.ghostty_alloc(0, len);
    assert.notEqual(ptr, 0, `allocation failed (${len} bytes)`);
    return ptr;
  }

  free(ptr, len) {
    if (ptr !== 0) this.e.ghostty_free(0, ptr, len);
  }

  cString(ptr) {
    const memory = new Uint8Array(this.e.memory.buffer);
    let end = ptr;
    while (memory[end] !== 0) ++end;
    return new TextDecoder().decode(memory.subarray(ptr, end));
  }

  layout(name) {
    const value = this.layouts[name];
    assert.ok(value, `missing ${name} from ghostty_type_json`);
    return value;
  }

  field(name, member) {
    const value = this.layout(name).fields[member];
    assert.ok(value, `missing ${name}.${member}`);
    return value.offset;
  }

  rawStruct(name) {
    const size = this.layout(name).size;
    const ptr = this.alloc(size);
    this.u8().fill(0, ptr, ptr + size);
    return { ptr, size, name };
  }

  struct(name) {
    const result = this.rawStruct(name);
    const fields = this.layout(name).fields;
    if (fields.size)
      this.view().setUint32(result.ptr + fields.size.offset, result.size, true);
    if (fields.version)
      this.view().setUint32(result.ptr + fields.version.offset, 1, true);
    return result;
  }

  dispose(value) {
    this.free(value.ptr, value.size);
  }
  getUsize(value, member) {
    return this.view().getUint32(
      value.ptr + this.field(value.name, member),
      true,
    );
  }
  setUsize(value, member, number) {
    this.view().setUint32(
      value.ptr + this.field(value.name, member),
      number,
      true,
    );
  }
  getI32(value, member) {
    return this.view().getInt32(
      value.ptr + this.field(value.name, member),
      true,
    );
  }
  setPtr(value, member, ptr) {
    this.view().setUint32(
      value.ptr + this.field(value.name, member),
      ptr,
      true,
    );
  }
  inlineString(value, member) {
    const stringPtr = value.ptr + this.field(value.name, member);
    const ptr = this.view().getUint32(
      stringPtr + this.field("GhosttyString", "ptr"),
      true,
    );
    const len = this.view().getUint32(
      stringPtr + this.field("GhosttyString", "len"),
      true,
    );
    return new TextDecoder().decode(this.u8().subarray(ptr, ptr + len));
  }

  terminal(columns = 40, rows = 8) {
    const slot = this.alloc(4);
    this.view().setUint32(slot, 0, true);
    assert.equal(this.e.ghostty_terminal_new(0, slot, columns, rows), SUCCESS);
    const terminal = this.view().getUint32(slot, true);
    this.free(slot, 4);
    assert.notEqual(terminal, 0);
    return terminal;
  }

  write(terminal, input) {
    const bytes =
      typeof input === "string" ? new TextEncoder().encode(input) : input;
    const ptr = this.alloc(bytes.length);
    this.u8().set(bytes, ptr);
    this.e.ghostty_terminal_vt_write(terminal, ptr, bytes.length);
    this.free(ptr, bytes.length);
  }

  terminalUsize(terminal, data) {
    const out = this.alloc(4);
    assert.equal(this.e.ghostty_terminal_get(terminal, data, out), SUCCESS);
    const value = this.view().getUint32(out, true);
    this.free(out, 4);
    return value;
  }

  unlimitedScrollback(terminal) {
    assert.equal(this.e.ghostty_terminal_set(terminal, 27, 0), SUCCESS);
  }

  gridText(terminal, tag, y, length) {
    const point = this.rawStruct("GhosttyPoint");
    const ref = this.struct("GhosttyGridRef");
    const codepoints = this.alloc(64 * 4);
    const written = this.alloc(4);
    const coordinate = point.ptr + this.field(point.name, "value");
    this.view().setInt32(point.ptr + this.field(point.name, "tag"), tag, true);
    this.view().setUint32(
      coordinate + this.field("GhosttyPointCoordinate", "y"),
      y,
      true,
    );
    let result = "";
    for (let x = 0; x < length; ++x) {
      this.view().setUint16(
        coordinate + this.field("GhosttyPointCoordinate", "x"),
        x,
        true,
      );
      assert.equal(
        this.e.ghostty_terminal_grid_ref(terminal, point.ptr, ref.ptr),
        SUCCESS,
      );
      this.view().setUint32(written, 0, true);
      assert.equal(
        this.e.ghostty_grid_ref_graphemes(ref.ptr, codepoints, 64, written),
        SUCCESS,
      );
      const count = this.view().getUint32(written, true);
      if (count === 0) {
        result += " ";
      } else {
        for (let index = 0; index < count; ++index) {
          result += String.fromCodePoint(
            this.view().getUint32(codepoints + index * 4, true));
        }
      }
    }
    this.free(written, 4);
    this.free(codepoints, 64 * 4);
    this.dispose(ref);
    this.dispose(point);
    return result;
  }
}

function terminalData(rt, terminal, kind, shape) {
  const output =
    typeof shape === "string"
      ? shape === "GhosttyString"
        ? rt.rawStruct(shape)
        : rt.struct(shape)
      : { ptr: rt.alloc(shape), size: shape, name: null };
  rt.u8().fill(0, output.ptr, output.ptr + output.size);
  if (output.name && rt.layout(output.name).fields.size) {
    rt.view().setUint32(
      output.ptr + rt.field(output.name, "size"),
      output.size,
      true,
    );
  }
  const status = rt.e.ghostty_terminal_get(terminal, kind, output.ptr);
  let value = new Uint8Array();
  if (status === SUCCESS && shape === "GhosttyString") {
    const ptr = rt.view().getUint32(output.ptr + rt.field(shape, "ptr"), true);
    const len = rt.view().getUint32(output.ptr + rt.field(shape, "len"), true);
    value = Uint8Array.from(rt.u8().subarray(ptr, ptr + len));
  } else if (status === SUCCESS) {
    value = Uint8Array.from(
      rt.u8().subarray(output.ptr, output.ptr + output.size),
    );
  }
  rt.free(output.ptr, output.size);
  return { status, value };
}

function assertTerminalMetadataEqual(rt, left, right) {
  const rgbSize = rt.layout("GhosttyColorRgb").size;
  const fields = [
    [1, 2],
    [2, 2],
    [3, 2],
    [4, 2],
    [5, 1],
    [6, 4],
    [7, 1],
    [8, 1],
    [9, "GhosttyTerminalScrollbar"],
    [10, "GhosttyStyle"],
    [11, 1],
    [12, "GhosttyString"],
    [13, "GhosttyString"],
    [14, 4],
    [15, 4],
    [16, 4],
    [17, 4],
    [18, rgbSize],
    [19, rgbSize],
    [20, rgbSize],
    [21, rgbSize * 256],
    [22, rgbSize],
    [23, rgbSize],
    [24, rgbSize],
    [25, rgbSize * 256],
    [32, 1],
    [33, 1],
    [34, 4],
    [35, 4],
  ];
  for (const [kind, shape] of fields) {
    assert.deepEqual(
      terminalData(rt, right, kind, shape),
      terminalData(rt, left, kind, shape),
      `terminal data ${kind}`,
    );
  }

  const ansiModes = [2, 4, 12, 20];
  const decModes = [
    1, 3, 4, 5, 6, 7, 8, 9, 12, 25, 40, 45, 47, 66, 67, 69, 1000, 1002, 1003,
    1004, 1005, 1006, 1007, 1015, 1016, 1035, 1036, 1039, 1045, 1047, 1048,
    1049, 2004, 2026, 2027, 2031, 2033, 2048,
  ];
  const leftValue = rt.alloc(1);
  const rightValue = rt.alloc(1);
  for (const mode of [
    ...ansiModes.map((value) => value | 0x8000),
    ...decModes,
  ]) {
    rt.u8()[leftValue] = 0;
    rt.u8()[rightValue] = 0;
    const leftStatus = rt.e.ghostty_terminal_mode_get(left, mode, leftValue);
    const rightStatus = rt.e.ghostty_terminal_mode_get(right, mode, rightValue);
    assert.equal(rightStatus, leftStatus, `mode ${mode} status`);
    if (leftStatus === SUCCESS) {
      assert.equal(rt.u8()[rightValue], rt.u8()[leftValue], `mode ${mode}`);
    }
  }
  rt.free(rightValue, 1);
  rt.free(leftValue, 1);
}

function setPoint(rt, point, tag, x, y) {
  const coordinate = point.ptr + rt.field(point.name, "value");
  rt.view().setInt32(point.ptr + rt.field(point.name, "tag"), tag, true);
  rt.view().setUint16(
    coordinate + rt.field("GhosttyPointCoordinate", "x"),
    x,
    true,
  );
  rt.view().setUint32(
    coordinate + rt.field("GhosttyPointCoordinate", "y"),
    y,
    true,
  );
}

function gridRef(rt, terminal, point, ref) {
  assert.equal(
    rt.e.ghostty_terminal_grid_ref(terminal, point.ptr, ref.ptr),
    SUCCESS,
  );
}

function cellData(rt, cell, kind, output) {
  rt.u8().fill(0, output, output + 16);
  const status = rt.e.ghostty_cell_get(cell, kind, output);
  return {
    status,
    value:
      status === SUCCESS
        ? Uint8Array.from(rt.u8().subarray(output, output + 16))
        : new Uint8Array(),
  };
}

function rowData(rt, row, kind, output) {
  rt.u8().fill(0, output, output + 8);
  const status = rt.e.ghostty_row_get(row, kind, output);
  return {
    status,
    value:
      status === SUCCESS
        ? Uint8Array.from(rt.u8().subarray(output, output + 8))
        : new Uint8Array(),
  };
}

function graphemes(rt, ref, buffer, written) {
  rt.view().setUint32(written, 0, true);
  const status = rt.e.ghostty_grid_ref_graphemes(ref.ptr, buffer, 64, written);
  assert.equal(status, SUCCESS);
  const count = rt.view().getUint32(written, true);
  assert.ok(count <= 64);
  return Uint8Array.from(rt.u8().subarray(buffer, buffer + count * 4));
}

function hyperlink(rt, ref, written) {
  rt.view().setUint32(written, 0, true);
  const status = rt.e.ghostty_grid_ref_hyperlink_uri(ref.ptr, 0, 0, written);
  const required = rt.view().getUint32(written, true);
  if (status === SUCCESS) {
    assert.equal(required, 0);
    return new Uint8Array();
  }
  assert.equal(status, RESULT_OUT_OF_SPACE);
  assert.ok(required > 0 && required <= 1024 * 1024);
  const buffer = rt.alloc(required);
  rt.view().setUint32(written, 0, true);
  assert.equal(
    rt.e.ghostty_grid_ref_hyperlink_uri(ref.ptr, buffer, required, written),
    SUCCESS,
  );
  assert.equal(rt.view().getUint32(written, true), required);
  const value = Uint8Array.from(rt.u8().subarray(buffer, buffer + required));
  rt.free(buffer, required);
  return value;
}

function resetSized(rt, value) {
  rt.u8().fill(0, value.ptr, value.ptr + value.size);
  rt.view().setUint32(
    value.ptr + rt.field(value.name, "size"),
    value.size,
    true,
  );
}

function assertGridEqual(rt, left, right) {
  const leftCols = terminalData(rt, left, 1, 2);
  const leftRows = terminalData(rt, left, 2, 2);
  const rightCols = terminalData(rt, right, 1, 2);
  const rightRows = terminalData(rt, right, 2, 2);
  assert.deepEqual(rightCols, leftCols);
  assert.deepEqual(rightRows, leftRows);
  const cols = leftCols.value[0] | (leftCols.value[1] << 8);
  const rows = leftRows.value[0] | (leftRows.value[1] << 8);
  const historyRows = rt.terminalUsize(left, 15);
  assert.equal(rt.terminalUsize(right, 15), historyRows);
  assert.equal(rt.terminalUsize(left, 14), historyRows + rows);
  assert.equal(rt.terminalUsize(right, 14), historyRows + rows);

  const leftPoint = rt.rawStruct("GhosttyPoint");
  const rightPoint = rt.rawStruct("GhosttyPoint");
  const leftRef = rt.struct("GhosttyGridRef");
  const rightRef = rt.struct("GhosttyGridRef");
  const leftCell = rt.alloc(8);
  const rightCell = rt.alloc(8);
  const leftRow = rt.alloc(8);
  const rightRow = rt.alloc(8);
  const leftOutput = rt.alloc(16);
  const rightOutput = rt.alloc(16);
  const leftGraphemes = rt.alloc(64 * 4);
  const rightGraphemes = rt.alloc(64 * 4);
  const leftWritten = rt.alloc(4);
  const rightWritten = rt.alloc(4);
  const leftStyle = rt.struct("GhosttyStyle");
  const rightStyle = rt.struct("GhosttyStyle");
  const stats = {
    styledCells: 0,
    hyperlinkCells: 0,
    multiCodepointCells: 0,
    wideCells: 0,
    softWrappedRows: 0,
    semanticRows: 0,
  };

  const compareRegion = (tag, regionRows, regionName) => {
    for (let y = 0; y < regionRows; ++y) {
      for (let x = 0; x < cols; ++x) {
        setPoint(rt, leftPoint, tag, x, y);
        setPoint(rt, rightPoint, tag, x, y);
        gridRef(rt, left, leftPoint, leftRef);
        gridRef(rt, right, rightPoint, rightRef);
        const label = `${regionName}[${y},${x}]`;

        assert.equal(
          rt.e.ghostty_grid_ref_cell(leftRef.ptr, leftCell),
          SUCCESS,
        );
        assert.equal(
          rt.e.ghostty_grid_ref_cell(rightRef.ptr, rightCell),
          SUCCESS,
        );
        const leftCellValue = rt.view().getBigUint64(leftCell, true);
        const rightCellValue = rt.view().getBigUint64(rightCell, true);
        let hasStyling = false;
        let hasHyperlink = false;
        for (let kind = 1; kind <= 11; ++kind) {
          const leftData = cellData(rt, leftCellValue, kind, leftOutput);
          const rightData = cellData(rt, rightCellValue, kind, rightOutput);
          assert.deepEqual(rightData, leftData, `${label} cell data ${kind}`);
          if (kind === 5) hasStyling = leftData.value[0] !== 0;
          if (kind === 7) hasHyperlink = leftData.value[0] !== 0;
          if (kind === 3 && leftData.value[0] !== 0) ++stats.wideCells;
        }
        if (hasStyling) ++stats.styledCells;
        if (hasHyperlink) ++stats.hyperlinkCells;
        const leftCluster = graphemes(rt, leftRef, leftGraphemes, leftWritten);
        const rightCluster = graphemes(
          rt,
          rightRef,
          rightGraphemes,
          rightWritten,
        );
        assert.deepEqual(rightCluster, leftCluster, `${label} graphemes`);
        if (leftCluster.length > 4) ++stats.multiCodepointCells;
        if (hasStyling) {
          resetSized(rt, leftStyle);
          resetSized(rt, rightStyle);
          assert.equal(
            rt.e.ghostty_grid_ref_style(leftRef.ptr, leftStyle.ptr),
            SUCCESS,
          );
          assert.equal(
            rt.e.ghostty_grid_ref_style(rightRef.ptr, rightStyle.ptr),
            SUCCESS,
          );
          assert.deepEqual(
            rt.u8().subarray(rightStyle.ptr, rightStyle.ptr + rightStyle.size),
            rt.u8().subarray(leftStyle.ptr, leftStyle.ptr + leftStyle.size),
            `${label} style`,
          );
        }
        if (hasHyperlink) {
          assert.deepEqual(
            hyperlink(rt, rightRef, rightWritten),
            hyperlink(rt, leftRef, leftWritten),
            `${label} hyperlink`,
          );
        }

        if (x === 0) {
          assert.equal(
            rt.e.ghostty_grid_ref_row(leftRef.ptr, leftRow),
            SUCCESS,
          );
          assert.equal(
            rt.e.ghostty_grid_ref_row(rightRef.ptr, rightRow),
            SUCCESS,
          );
          const leftRowValue = rt.view().getBigUint64(leftRow, true);
          const rightRowValue = rt.view().getBigUint64(rightRow, true);
          let softWrapped = false;
          let semantic = false;
          for (let kind = 1; kind <= 7; ++kind) {
            const leftData = rowData(rt, leftRowValue, kind, leftOutput);
            const rightData = rowData(rt, rightRowValue, kind, rightOutput);
            assert.deepEqual(
              rightData,
              leftData,
              `${regionName}[${y}] row data ${kind}`,
            );
            if ((kind === 1 || kind === 2) && leftData.value[0] !== 0) {
              softWrapped = true;
            }
            if (kind === 6 && leftData.value[0] !== 0) semantic = true;
          }
          if (softWrapped) ++stats.softWrappedRows;
          if (semantic) ++stats.semanticRows;
        }
      }
    }
  };

  compareRegion(3, historyRows, "history");
  compareRegion(0, rows, "active");

  rt.dispose(rightStyle);
  rt.dispose(leftStyle);
  rt.free(rightWritten, 4);
  rt.free(leftWritten, 4);
  rt.free(rightGraphemes, 64 * 4);
  rt.free(leftGraphemes, 64 * 4);
  rt.free(rightOutput, 16);
  rt.free(leftOutput, 16);
  rt.free(rightRow, 8);
  rt.free(leftRow, 8);
  rt.free(rightCell, 8);
  rt.free(leftCell, 8);
  rt.dispose(rightRef);
  rt.dispose(leftRef);
  rt.dispose(rightPoint);
  rt.dispose(leftPoint);
  return stats;
}

function captureOptions(rt, maxRecordBytes = 4 * 1024 * 1024) {
  const options = rt.struct("GhosttyTerminalSnapshotCaptureOptions");
  rt.setUsize(options, "max_record_bytes", maxRecordBytes);
  rt.setUsize(options, "max_pages", 4096);
  return options;
}

function decoderOptions(rt, maxRecordBytes = 4 * 1024 * 1024) {
  const options = rt.struct("GhosttyTerminalSnapshotDecoderOptions");
  rt.setUsize(options, "max_continuation_bytes", 1024 * 1024);
  rt.setUsize(options, "max_record_bytes", maxRecordBytes);
  rt.setUsize(options, "max_pages", 4096);
  return options;
}

function historyOptions(rt) {
  const options = rt.struct("GhosttyTerminalHistoryOptions");
  rt.setUsize(options, "max_unit_bytes", 256 * 1024);
  rt.setUsize(options, "max_rows", 32);
  rt.setUsize(options, "max_units", 4096);
  return options;
}

function captureAll(rt, terminal, allocator = 0) {
  const options = captureOptions(rt);
  const slot = rt.alloc(4);
  rt.view().setUint32(slot, 0, true);
  assert.equal(
    rt.e.ghostty_terminal_snapshot_capture_new(
      allocator,
      terminal,
      options.ptr,
      slot,
    ),
    SUCCESS,
  );
  const capture = rt.view().getUint32(slot, true);
  assert.notEqual(capture, 0);
  const records = [];
  let offset = 0;
  for (;;) {
    const probe = rt.struct("GhosttyTerminalSnapshotCaptureEvent");
    assert.equal(
      rt.e.ghostty_terminal_snapshot_capture_next(capture, 0, 0, probe.ptr),
      OUT_OF_SPACE,
    );
    assert.equal(rt.getUsize(probe, "written"), 0);
    const required = rt.getUsize(probe, "required_bytes");
    const kind = rt.getI32(probe, "kind");
    assert.ok(required > 0);
    const buffer = rt.alloc(required);
    if (required > 1) {
      const short = rt.struct("GhosttyTerminalSnapshotCaptureEvent");
      assert.equal(
        rt.e.ghostty_terminal_snapshot_capture_next(
          capture,
          buffer,
          required - 1,
          short.ptr,
        ),
        OUT_OF_SPACE,
      );
      assert.equal(rt.getUsize(short, "written"), 0);
      assert.equal(rt.getUsize(short, "required_bytes"), required);
      assert.equal(rt.getI32(short, "kind"), kind);
      rt.dispose(short);
    }
    const exact = rt.struct("GhosttyTerminalSnapshotCaptureEvent");
    assert.equal(
      rt.e.ghostty_terminal_snapshot_capture_next(
        capture,
        buffer,
        required,
        exact.ptr,
      ),
      SUCCESS,
    );
    assert.equal(rt.getUsize(exact, "written"), required);
    assert.equal(rt.getI32(exact, "kind"), kind);
    records.push({
      bytes: Uint8Array.from(rt.u8().subarray(buffer, buffer + required)),
      kind,
      offset,
      index: rt.getUsize(exact, "index"),
      count: rt.getUsize(exact, "count"),
      screenKey: rt
        .view()
        .getUint16(exact.ptr + rt.field(exact.name, "screen_key"), true),
    });
    offset += required;
    rt.free(buffer, required);
    rt.dispose(exact);
    rt.dispose(probe);
    if (kind === CAPTURE_FINISH) break;
  }
  assert.equal(rt.e.ghostty_terminal_snapshot_capture_abort(capture), SUCCESS);
  rt.e.ghostty_terminal_snapshot_capture_free(capture);
  rt.free(slot, 4);
  rt.dispose(options);
  const encoded = new Uint8Array(offset);
  for (const record of records) encoded.set(record.bytes, record.offset);
  return { encoded, records };
}

function exerciseCaptureLimit(rt, terminal) {
  const options = captureOptions(rt, 10);
  const slot = rt.alloc(4);
  rt.view().setUint32(slot, 0, true);
  assert.equal(
    rt.e.ghostty_terminal_snapshot_capture_new(0, terminal, options.ptr, slot),
    SUCCESS,
  );
  const capture = rt.view().getUint32(slot, true);
  const event = rt.struct("GhosttyTerminalSnapshotCaptureEvent");
  const buffer = rt.alloc(10);
  assert.equal(
    rt.e.ghostty_terminal_snapshot_capture_next(capture, buffer, 10, event.ptr),
    SUCCESS,
  );
  assert.equal(rt.getUsize(event, "written"), 10);
  assert.equal(
    rt.e.ghostty_terminal_snapshot_capture_next(capture, buffer, 10, event.ptr),
    LIMIT_EXCEEDED,
  );
  rt.e.ghostty_terminal_snapshot_capture_free(capture);
  rt.free(buffer, 10);
  rt.dispose(event);
  rt.free(slot, 4);
  rt.dispose(options);
}

function uleb(value) {
  const bytes = [];
  do {
    let byte = value & 0x7f;
    value >>>= 7;
    if (value !== 0) byte |= 0x80;
    bytes.push(byte);
  } while (value !== 0);
  return bytes;
}

function wasmSection(id, payload) {
  return [id, ...uleb(payload.length), ...payload];
}

function allocatorProxyModuleBytes() {
  const i32 = 0x7f;
  const type = (parameters, result) => [
    0x60,
    ...uleb(parameters),
    ...Array(parameters).fill(i32),
    result ? 1 : 0,
    ...(result ? [i32] : []),
  ];
  const types = [
    ...uleb(3),
    ...type(4, true),
    ...type(6, true),
    ...type(5, false),
  ];
  const string = (value) => {
    const bytes = new TextEncoder().encode(value);
    return [...uleb(bytes.length), ...bytes];
  };
  const importEntry = (name, typeIndex) => [
    ...string("host"),
    ...string(name),
    0,
    ...uleb(typeIndex),
  ];
  const imports = [
    ...uleb(4),
    ...importEntry("alloc", 0),
    ...importEntry("resize", 1),
    ...importEntry("remap", 1),
    ...importEntry("free", 2),
  ];
  const exportEntry = (name, index) => [...string(name), 0, ...uleb(index)];
  const exports = [
    ...uleb(4),
    ...exportEntry("alloc", 0),
    ...exportEntry("resize", 1),
    ...exportEntry("remap", 2),
    ...exportEntry("free", 3),
  ];
  return new Uint8Array([
    0,
    0x61,
    0x73,
    0x6d,
    1,
    0,
    0,
    0,
    ...wasmSection(1, types),
    ...wasmSection(2, imports),
    ...wasmSection(7, exports),
  ]);
}

async function makeTrackingAllocator(rt) {
  const state = {
    calls: { alloc: 0, resize: 0, remap: 0, free: 0 },
    allocations: new Map(),
    failAfter: Number.POSITIVE_INFINITY,
    invalidFree: false,
  };
  const host = {
    alloc(_ctx, len) {
      ++state.calls.alloc;
      if (state.calls.alloc > state.failAfter) return 0;
      const ptr = rt.e.ghostty_alloc(0, len >>> 0);
      if (ptr !== 0) state.allocations.set(ptr >>> 0, len >>> 0);
      return ptr;
    },
    resize() {
      ++state.calls.resize;
      return 0;
    },
    remap() {
      ++state.calls.remap;
      return 0;
    },
    free(_ctx, memory, memoryLen) {
      ++state.calls.free;
      memory >>>= 0;
      memoryLen >>>= 0;
      if (state.allocations.get(memory) !== memoryLen) {
        state.invalidFree = true;
        return;
      }
      state.allocations.delete(memory);
      rt.e.ghostty_free(0, memory, memoryLen);
    },
  };
  const helper = await WebAssembly.instantiate(allocatorProxyModuleBytes(), {
    host,
  });
  const table = Object.values(rt.e).find(
    (value) => value instanceof WebAssembly.Table,
  );
  assert.ok(table, "standalone wasm must export its indirect function table");
  const base = table.grow(4);
  const functions = ["alloc", "resize", "remap", "free"];
  functions.forEach((name, index) => {
    const callback = helper.instance.exports[name];
    table.set(base + index, callback);
    assert.equal(table.get(base + index), callback);
  });
  const context = rt.alloc(1);
  const vtable = rt.rawStruct("GhosttyAllocatorVtable");
  functions.forEach((name, index) => {
    const field = vtable.ptr + rt.field(vtable.name, name);
    rt.view().setUint32(field, base + index, true);
    assert.equal(rt.view().getUint32(field, true), base + index);
  });
  const allocator = rt.rawStruct("GhosttyAllocator");
  rt.setPtr(allocator, "ctx", context);
  rt.setPtr(allocator, "vtable", vtable.ptr);
  return {
    ptr: allocator.ptr,
    state,
    probeResizeSignatures() {
      const resizeCalls = state.calls.resize;
      const remapCalls = state.calls.remap;
      assert.equal(helper.instance.exports.resize(0, 0, 0, 0, 0, 0), 0);
      assert.equal(helper.instance.exports.remap(0, 0, 0, 0, 0, 0), 0);
      assert.equal(state.calls.resize, resizeCalls + 1);
      assert.equal(state.calls.remap, remapCalls + 1);
    },
    reset(failAfter = Number.POSITIVE_INFINITY) {
      state.calls = { alloc: 0, resize: 0, remap: 0, free: 0 };
      state.failAfter = failAfter;
      state.invalidFree = false;
      assert.equal(state.allocations.size, 0);
    },
    dispose() {
      assert.equal(state.allocations.size, 0);
      assert.equal(state.invalidFree, false);
      rt.dispose(allocator);
      rt.dispose(vtable);
      rt.free(context, 1);
    },
  };
}

function expectDecodeError(
  rt,
  bytes,
  expected,
  maxRecordBytes = 4 * 1024 * 1024,
) {
  const options = decoderOptions(rt, maxRecordBytes);
  const slot = rt.alloc(4);
  rt.view().setUint32(slot, 0, true);
  assert.equal(
    rt.e.ghostty_terminal_snapshot_decoder_new(0, options.ptr, slot),
    SUCCESS,
  );
  const decoder = rt.view().getUint32(slot, true);
  const input = rt.alloc(bytes.length);
  rt.u8().set(bytes, input);
  let offset = 0;
  let terminal = 0;
  let status = SUCCESS;
  while (offset < bytes.length && status === SUCCESS) {
    const event = rt.struct("GhosttyTerminalSnapshotDecodeEvent");
    status = rt.e.ghostty_terminal_snapshot_decoder_push(
      decoder,
      input + offset,
      bytes.length - offset,
      event.ptr,
    );
    offset += rt.getUsize(event, "consumed");
    if (status === SUCCESS && rt.getI32(event, "kind") === DECODE_READY) {
      const take = rt.struct("GhosttyTerminalSnapshotTakeTerminalResult");
      assert.equal(
        rt.e.ghostty_terminal_snapshot_decoder_take_terminal(decoder, take.ptr),
        SUCCESS,
      );
      terminal = rt
        .view()
        .getUint32(take.ptr + rt.field(take.name, "terminal"), true);
      assert.equal(
        rt.e.ghostty_terminal_snapshot_decoder_replay_continuation(
          decoder,
          terminal,
        ),
        SUCCESS,
      );
      rt.dispose(take);
    }
    rt.dispose(event);
  }
  assert.equal(status, expected);
  assert.equal(rt.e.ghostty_terminal_snapshot_decoder_abort(decoder), SUCCESS);
  rt.e.ghostty_terminal_snapshot_decoder_free(decoder);
  if (terminal !== 0) rt.e.ghostty_terminal_free(terminal);
  rt.free(input, bytes.length);
  rt.free(slot, 4);
  rt.dispose(options);
}

function historyTransfer(rt, source, destination, checkpointOwner) {
  const options = historyOptions(rt);
  const wrongGeneration = rt.struct("GhosttyTerminalHistoryLeaseResult");
  assert.equal(
    rt.e.ghostty_terminal_history_lease_new(
      0,
      source,
      0xffff,
      wrongGeneration.ptr,
    ),
    WRONG_GENERATION,
  );
  rt.dispose(wrongGeneration);

  const lease = rt.struct("GhosttyTerminalHistoryLeaseResult");
  assert.equal(
    rt.e.ghostty_terminal_history_lease_new(0, source, 0, lease.ptr),
    SUCCESS,
  );
  const leaseHandle = rt
    .view()
    .getUint32(lease.ptr + rt.field(lease.name, "lease"), true);
  const checkpoint = lease.ptr + rt.field(lease.name, "checkpoint");
  assert.notEqual(leaseHandle, 0);

  const cursor = rt.struct("GhosttyTerminalHistoryCursorResult");
  assert.equal(
    rt.e.ghostty_terminal_history_lease_cursor(leaseHandle, source, cursor.ptr),
    SUCCESS,
  );
  const cursorHandle = rt
    .view()
    .getUint32(cursor.ptr + rt.field(cursor.name, "cursor"), true);
  assert.notEqual(cursorHandle, 0);
  const secondCursor = rt.struct("GhosttyTerminalHistoryCursorResult");
  assert.equal(
    rt.e.ghostty_terminal_history_lease_cursor(
      leaseHandle,
      source,
      secondCursor.ptr,
    ),
    INVALID_STATE,
  );
  rt.dispose(secondCursor);

  const wrongCursorEvent = rt.struct("GhosttyTerminalHistoryEvent");
  assert.equal(
    rt.e.ghostty_terminal_history_cursor_next(
      cursorHandle,
      destination,
      options.ptr,
      0,
      0,
      wrongCursorEvent.ptr,
    ),
    WRONG_TERMINAL,
  );
  rt.dispose(wrongCursorEvent);

  const token = rt.rawStruct("GhosttyTerminalHistoryToken");
  rt.u8().set(rt.u8().subarray(checkpoint, checkpoint + token.size), token.ptr);
  const tokenBytes = token.ptr + rt.field(token.name, "bytes");
  rt.u8()[tokenBytes + 31] ^= 0x80;
  const rejected = rt.struct("GhosttyTerminalHistoryImporterResult");
  assert.equal(
    rt.e.ghostty_terminal_history_importer_new(
      0,
      destination,
      0,
      source,
      token.ptr,
      options.ptr,
      rejected.ptr,
    ),
    INVALID_HANDLE,
  );
  rt.dispose(rejected);
  rt.dispose(token);

  const wrongImporter = rt.struct("GhosttyTerminalHistoryImporterResult");
  assert.equal(
    rt.e.ghostty_terminal_history_importer_new(
      0,
      destination,
      0xffff,
      source,
      checkpoint,
      options.ptr,
      wrongImporter.ptr,
    ),
    WRONG_GENERATION,
  );
  rt.dispose(wrongImporter);

  const importer = rt.struct("GhosttyTerminalHistoryImporterResult");
  assert.equal(
    rt.e.ghostty_terminal_history_importer_new(
      0,
      destination,
      0,
      source,
      checkpoint,
      options.ptr,
      importer.ptr,
    ),
    SUCCESS,
  );
  const importerHandle = rt
    .view()
    .getUint32(importer.ptr + rt.field(importer.name, "importer"), true);
  assert.notEqual(importerHandle, 0);
  const busy = rt.struct("GhosttyTerminalHistoryImporterResult");
  assert.equal(
    rt.e.ghostty_terminal_history_importer_new(
      0,
      destination,
      0,
      source,
      checkpoint,
      options.ptr,
      busy.ptr,
    ),
    IMPORT_BUSY,
  );
  rt.dispose(busy);

  let unitCount = 0;
  let corrupted = false;
  for (;;) {
    const probe = rt.struct("GhosttyTerminalHistoryEvent");
    const probeStatus = rt.e.ghostty_terminal_history_cursor_next(
      cursorHandle,
      source,
      options.ptr,
      0,
      0,
      probe.ptr,
    );
    if (probeStatus === SUCCESS) {
      assert.equal(rt.getI32(probe, "kind"), HISTORY_END);
      rt.dispose(probe);
      break;
    }
    assert.equal(probeStatus, OUT_OF_SPACE);
    const required = rt.getUsize(probe, "required_bytes");
    assert.ok(required > 0);
    const unit = rt.alloc(required);
    if (required > 1) {
      const short = rt.struct("GhosttyTerminalHistoryEvent");
      assert.equal(
        rt.e.ghostty_terminal_history_cursor_next(
          cursorHandle,
          source,
          options.ptr,
          unit,
          required - 1,
          short.ptr,
        ),
        OUT_OF_SPACE,
      );
      assert.equal(rt.getUsize(short, "written"), 0);
      assert.equal(rt.getUsize(short, "required_bytes"), required);
      rt.dispose(short);
    }
    const exact = rt.struct("GhosttyTerminalHistoryEvent");
    assert.equal(
      rt.e.ghostty_terminal_history_cursor_next(
        cursorHandle,
        source,
        options.ptr,
        unit,
        required,
        exact.ptr,
      ),
      SUCCESS,
    );
    assert.equal(rt.getI32(exact, "kind"), HISTORY_UNIT);
    const written = rt.getUsize(exact, "written");
    assert.equal(written, required);

    const imported = rt.struct("GhosttyTerminalHistoryImportEvent");
    if (!corrupted) {
      rt.u8()[unit + written - 1] ^= 0x40;
      for (let attempt = 0; attempt < 1024; ++attempt) {
        assert.equal(
          rt.e.ghostty_terminal_history_importer_push(
            importerHandle,
            destination,
            unit,
            written,
            options.ptr,
            imported.ptr,
          ),
          CORRUPTION,
        );
        assert.equal(rt.getUsize(imported, "consumed"), 0);
      }
      rt.u8()[unit + written - 1] ^= 0x40;
      corrupted = true;
    }
    assert.equal(
      rt.e.ghostty_terminal_history_importer_push(
        importerHandle,
        source,
        unit,
        written,
        options.ptr,
        imported.ptr,
      ),
      WRONG_TERMINAL,
    );
    if (written > 1) {
      rt.setUsize(options, "max_unit_bytes", written - 1);
      assert.equal(
        rt.e.ghostty_terminal_history_importer_push(
          importerHandle,
          destination,
          unit,
          written,
          options.ptr,
          imported.ptr,
        ),
        OUT_OF_SPACE,
      );
      assert.equal(rt.getUsize(imported, "consumed"), 0);
      assert.equal(rt.getUsize(imported, "required_bytes"), written);
      rt.setUsize(options, "max_unit_bytes", 256 * 1024);
    }
    assert.equal(
      rt.e.ghostty_terminal_history_importer_push(
        importerHandle,
        destination,
        unit,
        written,
        options.ptr,
        imported.ptr,
      ),
      SUCCESS,
    );
    assert.equal(rt.getUsize(imported, "consumed"), written);
    assert.equal(
      rt.view().getUint8(imported.ptr + rt.field(imported.name, "retained")),
      1,
    );
    ++unitCount;
    rt.write(
      destination,
      new TextEncoder().encode(`\x1b[32mlive-pty-${unitCount}\x1b[0m\r\n`),
    );

    rt.dispose(imported);
    rt.dispose(exact);
    rt.free(unit, required);
    rt.dispose(probe);
  }
  assert.ok(corrupted);
  assert.ok(unitCount > 1, "history smoke requires multiple bounded units");
  assert.equal(
    rt.e.ghostty_terminal_history_importer_commit(importerHandle, destination),
    SUCCESS,
  );
  rt.e.ghostty_terminal_history_importer_free(importerHandle);
  assert.ok(rt.terminalUsize(destination, 15) > 0);
  assert.equal(rt.gridText(destination, 3, 0, 8), "row-0000");
  const liveText = `live-pty-${unitCount}`;
  assert.equal(
    rt.gridText(destination, 0, Math.min(unitCount - 1, 6), liveText.length),
    liveText,
  );

  const aborted = rt.struct("GhosttyTerminalHistoryImporterResult");
  assert.equal(
    rt.e.ghostty_terminal_history_importer_new(
      0,
      destination,
      0,
      source,
      checkpoint,
      options.ptr,
      aborted.ptr,
    ),
    SUCCESS,
  );
  const abortedHandle = rt
    .view()
    .getUint32(aborted.ptr + rt.field(aborted.name, "importer"), true);
  assert.equal(
    rt.e.ghostty_terminal_history_importer_abort(abortedHandle, source),
    WRONG_TERMINAL,
  );
  assert.equal(
    rt.e.ghostty_terminal_history_importer_abort(abortedHandle, destination),
    SUCCESS,
  );
  rt.e.ghostty_terminal_history_importer_free(abortedHandle);

  rt.e.ghostty_terminal_history_cursor_free(cursorHandle);
  rt.e.ghostty_terminal_history_lease_free(leaseHandle);
  checkpointOwner.value = Uint8Array.from(
    rt
      .u8()
      .subarray(
        checkpoint,
        checkpoint + rt.layout("GhosttyTerminalHistoryToken").size,
      ),
  );
  rt.dispose(aborted);
  rt.dispose(importer);
  rt.dispose(cursor);
  rt.dispose(lease);
  rt.dispose(options);
}

async function exerciseEntropyFailure() {
  let failEntropy = false;
  const rt = await instantiateRuntime((getMemory, ptr, len) =>
    failEntropy ? -1 : secureEntropy(getMemory, ptr, len),
  );
  const source = rt.terminal();
  const destination = rt.terminal();
  rt.write(source, "entropy-contract\r\n".repeat(20));
  const lease = rt.struct("GhosttyTerminalHistoryLeaseResult");
  assert.equal(
    rt.e.ghostty_terminal_history_lease_new(0, source, 0, lease.ptr),
    SUCCESS,
  );
  const leaseHandle = rt
    .view()
    .getUint32(lease.ptr + rt.field(lease.name, "lease"), true);
  const checkpoint = lease.ptr + rt.field(lease.name, "checkpoint");
  failEntropy = true;
  const unavailableLease = rt.struct("GhosttyTerminalHistoryLeaseResult");
  assert.equal(
    rt.e.ghostty_terminal_history_lease_new(0, source, 0, unavailableLease.ptr),
    ENTROPY_UNAVAILABLE,
  );
  assert.equal(
    rt
      .view()
      .getUint32(
        unavailableLease.ptr + rt.field(unavailableLease.name, "lease"),
        true,
      ),
    0,
  );
  const options = historyOptions(rt);
  const unavailableImporter = rt.struct("GhosttyTerminalHistoryImporterResult");
  assert.equal(
    rt.e.ghostty_terminal_history_importer_new(
      0,
      destination,
      0,
      source,
      checkpoint,
      options.ptr,
      unavailableImporter.ptr,
    ),
    ENTROPY_UNAVAILABLE,
  );
  assert.equal(
    rt
      .view()
      .getUint32(
        unavailableImporter.ptr +
          rt.field(unavailableImporter.name, "importer"),
        true,
      ),
    0,
  );
  rt.e.ghostty_terminal_history_lease_free(leaseHandle);
  rt.e.ghostty_terminal_free(destination);
  rt.e.ghostty_terminal_free(source);
  rt.dispose(unavailableImporter);
  rt.dispose(options);
  rt.dispose(unavailableLease);
  rt.dispose(lease);
}

const rt = await instantiateRuntime();
const capabilities = rt.struct(
  "GhosttyTerminalSnapshotIncrementalCapabilities",
);
assert.equal(
  rt.e.ghostty_terminal_snapshot_incremental_capabilities(capabilities.ptr),
  SUCCESS,
);
for (const member of [
  "incremental",
  "ready",
  "history",
  "authenticated_tokens",
  "bounded_records",
  "bounded_pages",
  "bounded_units",
]) {
  assert.equal(
    rt.view().getUint8(capabilities.ptr + rt.field(capabilities.name, member)),
    1,
    member,
  );
}
assert.equal(
  rt
    .view()
    .getUint16(
      capabilities.ptr + rt.field(capabilities.name, "default_encode_version"),
      true,
    ),
  2,
);
const codecIdentity = rt.inlineString(capabilities, "codec_identity");
const buildIdentity = rt.inlineString(capabilities, "build_identity");
assert.equal(codecIdentity, "ghostty.snapshot.v1-v2.incremental.v1");
assert.ok(buildIdentity.length > 0);
const buildInfo = rt.rawStruct("GhosttyString");
assert.equal(rt.e.ghostty_build_info(5, buildInfo.ptr), SUCCESS);
const queriedBuildIdentity = new TextDecoder().decode(
  rt
    .u8()
    .subarray(
      rt
        .view()
        .getUint32(buildInfo.ptr + rt.field(buildInfo.name, "ptr"), true),
      rt
        .view()
        .getUint32(buildInfo.ptr + rt.field(buildInfo.name, "ptr"), true) +
        rt
          .view()
          .getUint32(buildInfo.ptr + rt.field(buildInfo.name, "len"), true),
    ),
);
assert.equal(buildIdentity, queriedBuildIdentity);
rt.dispose(buildInfo);
rt.dispose(capabilities);

const source = rt.terminal();
rt.unlimitedScrollback(source);
let sourceText = "";
for (let index = 0; index < 2000; ++index) {
  sourceText += `row-${String(index).padStart(4, "0")}\r\n`;
}
rt.write(source, sourceText);
assert.ok(rt.terminalUsize(source, 15) > 1000);
exerciseCaptureLimit(rt, source);
const trackingAllocator = await makeTrackingAllocator(rt);
trackingAllocator.probeResizeSignatures();
trackingAllocator.reset();
const allocatorCapture = captureAll(rt, source, trackingAllocator.ptr);
assert.ok(
  allocatorCapture.records.some(
    (record) => record.kind === CAPTURE_HISTORY_PAGE,
  ),
);
for (const callback of ["alloc", "free"]) {
  assert.ok(trackingAllocator.state.calls[callback] > 0, callback);
}
assert.equal(trackingAllocator.state.allocations.size, 0);
assert.equal(trackingAllocator.state.invalidFree, false);

trackingAllocator.reset(1);
const oomOptions = captureOptions(rt);
const oomSlot = rt.alloc(4);
rt.view().setUint32(oomSlot, 0, true);
assert.equal(
  rt.e.ghostty_terminal_snapshot_capture_new(
    trackingAllocator.ptr,
    source,
    oomOptions.ptr,
    oomSlot,
  ),
  OUT_OF_MEMORY,
);
assert.equal(rt.view().getUint32(oomSlot, true), 0);
assert.ok(trackingAllocator.state.calls.alloc >= 2);
assert.ok(trackingAllocator.state.calls.free >= 1);
assert.equal(trackingAllocator.state.allocations.size, 0);
assert.equal(trackingAllocator.state.invalidFree, false);
trackingAllocator.dispose();
rt.free(oomSlot, 4);
rt.dispose(oomOptions);
const seededHistoryRows = rt.terminalUsize(source, 15);
assert.equal(rt.gridText(source, 3, 0, 8), "row-0000");
assert.equal(
  rt.gridText(source, 3, seededHistoryRows - 1, 8), "row-1992");
const alternateOn = "\x1b[?47h";
const alternateOff = "\x1b[?47l";
rt.write(source, alternateOn);
rt.write(
  source,
  "\x1b[?2027h\x1b]133;A\x07\x1b[1;31m" +
    "\x1b]8;;https://example.test/checkpoint\x1b\\" +
    "ALT-e\u0301-界-" + "wrapped-".repeat(12) +
    "\x1b]8;;\x1b\\\x1b[0m\x1b]133;B\x07",
);
rt.write(source, alternateOff);
// DEC 47 preserves the alternate screen but shares the cursor column. Reset
// primary to column zero without changing its exact history boundary.
rt.write(source, "\r");
assert.equal(rt.gridText(source, 3, 0, 8), "row-0000");
assert.equal(
  rt.gridText(source, 3, seededHistoryRows - 1, 8), "row-1992");
rt.write(source, "\x1b[31");

const captured = captureAll(rt, source);
assert.ok(captured.records.some((record) => record.kind === CAPTURE_RECORD));
assert.ok(captured.records.some((record) => record.kind === CAPTURE_READY));
const historyBegin = captured.records.find(
  (record) =>
    record.kind === CAPTURE_HISTORY_BEGIN &&
    record.screenKey === 0 &&
    record.count > 0,
);
assert.ok(historyBegin, "capture must expose nonempty primary history");
const historyPages = captured.records.filter(
  (record) =>
    record.kind === CAPTURE_HISTORY_PAGE &&
    record.screenKey === historyBegin.screenKey,
);
assert.equal(historyPages.length, historyBegin.count);
historyPages.forEach((record, index) => {
  assert.equal(record.index, index);
  assert.equal(record.count, historyBegin.count);
  assert.ok(record.bytes.length > 0);
});
assert.equal(captured.records.at(-1).kind, CAPTURE_FINISH);
const finishOffset = captured.records.find(
  (record) => record.kind === CAPTURE_FINISH,
).offset;

const encodedPtr = rt.alloc(captured.encoded.length);
rt.u8().set(captured.encoded, encodedPtr);
const decodeOptions = decoderOptions(rt);
const decoderSlot = rt.alloc(4);
rt.view().setUint32(decoderSlot, 0, true);
assert.equal(
  rt.e.ghostty_terminal_snapshot_decoder_new(0, decodeOptions.ptr, decoderSlot),
  SUCCESS,
);
const decoder = rt.view().getUint32(decoderSlot, true);
const fragments = [1, 7, 2, 31, 3, 64, 5, 127, 11, 4];
let fragmentIndex = 0;
let offset = 0;
let decodedTerminal = 0;
let sawReady = false;
let sawFinish = false;
while (!sawReady) {
  const event = rt.struct("GhosttyTerminalSnapshotDecodeEvent");
  const offered = Math.min(
    fragments[fragmentIndex++ % fragments.length],
    captured.encoded.length - offset,
  );
  assert.ok(offered > 0);
  assert.equal(
    rt.e.ghostty_terminal_snapshot_decoder_push(
      decoder,
      encodedPtr + offset,
      offered,
      event.ptr,
    ),
    SUCCESS,
  );
  const consumed = rt.getUsize(event, "consumed");
  assert.ok(consumed > 0 && consumed <= offered);
  offset += consumed;
  if (rt.getI32(event, "kind") === DECODE_READY) {
    const blocked = rt.struct("GhosttyTerminalSnapshotDecodeEvent");
    assert.equal(
      rt.e.ghostty_terminal_snapshot_decoder_push(
        decoder,
        encodedPtr + offset,
        1,
        blocked.ptr,
      ),
      INVALID_STATE,
    );
    assert.equal(rt.getUsize(blocked, "consumed"), 0);
    rt.dispose(blocked);
    const take = rt.struct("GhosttyTerminalSnapshotTakeTerminalResult");
    assert.equal(
      rt.e.ghostty_terminal_snapshot_decoder_take_terminal(decoder, take.ptr),
      SUCCESS,
    );
    decodedTerminal = rt
      .view()
      .getUint32(take.ptr + rt.field(take.name, "terminal"), true);
    assert.notEqual(decodedTerminal, 0);
    rt.unlimitedScrollback(decodedTerminal);
    const secondTake = rt.struct("GhosttyTerminalSnapshotTakeTerminalResult");
    assert.equal(
      rt.e.ghostty_terminal_snapshot_decoder_take_terminal(
        decoder,
        secondTake.ptr,
      ),
      INVALID_STATE,
    );
    rt.dispose(secondTake);
    const wrong = rt.terminal();
    assert.equal(
      rt.e.ghostty_terminal_snapshot_decoder_replay_continuation(
        decoder,
        wrong,
      ),
      WRONG_TERMINAL,
    );
    rt.e.ghostty_terminal_free(wrong);
    assert.equal(
      rt.e.ghostty_terminal_snapshot_decoder_replay_continuation(
        decoder,
        decodedTerminal,
      ),
      SUCCESS,
    );
    assert.equal(
      rt.e.ghostty_terminal_snapshot_decoder_replay_continuation(
        decoder,
        decodedTerminal,
      ),
      INVALID_STATE,
    );
    rt.dispose(take);
    sawReady = true;
  }
  rt.dispose(event);
}

// Both terminals held the split "ESC [ 31" parser prefix at the cut. Only a
// successful one-shot continuation replay makes this suffix produce identical
// terminal snapshots after the remaining history stream reaches FINISH.
const parserSuffix = "mparser-continuation-replayed\x1b[0m\r\n";
rt.write(source, parserSuffix);
rt.write(decodedTerminal, parserSuffix);
const historyDestination = rt.terminal();
rt.unlimitedScrollback(historyDestination);
const sourceHistoryRows = rt.terminalUsize(source, 15);
assert.ok(sourceHistoryRows > 1000);
assert.equal(rt.gridText(source, 3, 0, 8), "row-0000");
// Column-zero normalization keeps the completed SGR text on one row, so its
// CRLF advances exactly row-1993 into history on both READY/source terminals.
assert.equal(rt.gridText(
  source, 3, sourceHistoryRows - 1, 8), "row-1993");
const checkpointOwner = { value: null };
historyTransfer(rt, source, historyDestination, checkpointOwner);
assert.ok(checkpointOwner.value.some((byte) => byte !== 0));

let decodedHistoryCount = null;
let decodedHistoryPages = 0;
while (!sawFinish) {
  const event = rt.struct("GhosttyTerminalSnapshotDecodeEvent");
  const offered = Math.min(
    fragments[fragmentIndex++ % fragments.length],
    captured.encoded.length - offset,
  );
  assert.ok(offered > 0);
  assert.equal(
    rt.e.ghostty_terminal_snapshot_decoder_push(
      decoder,
      encodedPtr + offset,
      offered,
      event.ptr,
    ),
    SUCCESS,
  );
  const consumed = rt.getUsize(event, "consumed");
  assert.ok(consumed > 0 && consumed <= offered);
  offset += consumed;
  const kind = rt.getI32(event, "kind");
  const screenKey = rt
    .view()
    .getUint16(event.ptr + rt.field(event.name, "screen_key"), true);
  if (kind === DECODE_HISTORY_BEGIN && screenKey === historyBegin.screenKey) {
    decodedHistoryCount = rt.getUsize(event, "count");
    assert.equal(decodedHistoryCount, historyBegin.count);
  } else if (
    kind === DECODE_HISTORY_PAGE &&
    screenKey === historyBegin.screenKey
  ) {
    assert.notEqual(decodedHistoryCount, null);
    assert.equal(rt.getUsize(event, "index"), decodedHistoryPages);
    assert.equal(rt.getUsize(event, "count"), decodedHistoryCount);
    assert.equal(
      rt.view().getUint8(event.ptr + rt.field(event.name, "retained")),
      1,
    );
    ++decodedHistoryPages;
  }
  sawFinish = kind === DECODE_FINISH;
  rt.dispose(event);
}
assert.equal(offset, captured.encoded.length);
assert.equal(decodedHistoryPages, decodedHistoryCount);
rt.e.ghostty_terminal_snapshot_decoder_free(decoder);

// PAGE record boundaries reflect private PageList storage partitioning. Live
// writes during incremental prepend can repartition equivalent rows, so raw
// recapture bytes are not canonical. Prove the public terminal contract
// exhaustively instead: canonical metadata/modes plus every history and active
// cell's graphemes, cell/row invariants, style, and bounded hyperlink bytes.
const continuationText = "parser-continuation-replayed";
assert.equal(
  rt.gridText(source, 0, 6, continuationText.length),
  continuationText,
);
assert.equal(
  rt.gridText(decodedTerminal, 0, 6, continuationText.length),
  continuationText,
);
assertTerminalMetadataEqual(rt, source, decodedTerminal);
assertGridEqual(rt, source, decodedTerminal);

// The snapshot also owns the inactive alternate screen. Switch with DEC 47
// (which preserves its contents), prove the non-default branches are real,
// and then return both terminals to primary.
rt.write(source, alternateOn);
rt.write(decodedTerminal, alternateOn);
assert.equal(rt.gridText(source, 0, 0, 4), "ALT-");
assert.equal(rt.gridText(decodedTerminal, 0, 0, 4), "ALT-");
assertTerminalMetadataEqual(rt, source, decodedTerminal);
const alternateStats = assertGridEqual(rt, source, decodedTerminal);
for (const feature of [
  "styledCells",
  "hyperlinkCells",
  "multiCodepointCells",
  "wideCells",
  "softWrappedRows",
  "semanticRows",
]) {
  assert.ok(alternateStats[feature] > 0, `alternate ${feature}`);
}
rt.write(source, alternateOff);
rt.write(decodedTerminal, alternateOff);
assert.equal(
  rt.gridText(source, 0, 6, continuationText.length),
  continuationText,
);
assert.equal(
  rt.gridText(decodedTerminal, 0, 6, continuationText.length),
  continuationText,
);

const unknownVersion = Uint8Array.from(captured.encoded);
unknownVersion[8] = 0xff;
unknownVersion[9] = 0x7f;
expectDecodeError(rt, unknownVersion, UNKNOWN_VERSION);
const corruptChecksum = Uint8Array.from(captured.encoded);
corruptChecksum[finishOffset + 10] ^= 0x80;
expectDecodeError(rt, corruptChecksum, CORRUPTION);
expectDecodeError(rt, captured.encoded, LIMIT_EXCEEDED, 1);

await exerciseEntropyFailure();

rt.e.ghostty_terminal_free(historyDestination);
rt.e.ghostty_terminal_free(decodedTerminal);
rt.e.ghostty_terminal_free(source);
rt.free(encodedPtr, captured.encoded.length);
rt.free(decoderSlot, 4);
rt.dispose(decodeOptions);
console.log("standalone incremental snapshot wasm smoke: ok");
