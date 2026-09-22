import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(here, "..", "dist", "module.js");

const EDITORS = [
  "addSelect",
  "addFieldNamePicker",
  "addNumberInput",
  "addColorPicker",
  "addTextInput",
  "addBooleanSwitch",
  "addTextArea",
];

function makeBuilder() {
  const calls = [];
  const builder = {};
  for (const editor of EDITORS) {
    builder[editor] = (options) => {
      calls.push({ editor, options });
      return builder;
    };
  }
  builder.calls = calls;
  return builder;
}

function loadPluginFactory() {
  const code = fs.readFileSync(dist, "utf8");
  let captured = null;
  const sandbox = {
    console,
    define: (deps, factory) => {
      captured = { deps, factory };
    },
  };
  sandbox.globalThis = sandbox;
  vm.runInNewContext(code, sandbox, { filename: "module.js" });
  assert.ok(captured, "the bundle must register an AMD module via define()");
  return { captured, sandbox };
}

test("the bundle exposes the Grafana AMD contract", () => {
  const { captured, sandbox } = loadPluginFactory();
  assert.deepEqual(Array.from(captured.deps), ["react", "@grafana/data"]);
  assert.ok(sandbox.GwTreemapConstraints, "geometry helpers must be on the global");
  assert.equal(typeof sandbox.GwTreemapConstraints.layoutTreemap, "function");
  assert.equal(typeof sandbox.GwTreemapConstraints.lineFit, "function");
});

test("the factory registers a panel plugin with all options", () => {
  const { captured } = loadPluginFactory();
  const builder = makeBuilder();
  class PanelPlugin {
    useFieldConfig() {
      return this;
    }
    setPanelOptions(cb) {
      cb(builder);
      return this;
    }
  }
  const React = { createElement: () => null, useMemo: (f) => f(), useState: () => [null, () => {}], useRef: () => ({ current: null }) };
  const data = { PanelPlugin };
  const exports = captured.factory(React, data);

  assert.ok(exports.plugin instanceof PanelPlugin, "must export { plugin }");
  const paths = builder.calls.map((call) => call.options.path);
  for (const required of [
    "tiling",
    "textField",
    "sizeField",
    "minTileArea",
    "maxTileArea",
    "tooltipTemplate",
    "autoFontSize",
  ]) {
    assert.ok(paths.includes(required), `missing option ${required}`);
  }
});
