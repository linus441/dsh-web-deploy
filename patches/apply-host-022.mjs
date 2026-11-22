import fs from "node:fs";
import path from "node:path";

const appRoot = process.argv[2];
if (!appRoot) {
  console.error("usage: node apply-host-022.mjs <app-root>");
  process.exit(2);
}
const root = path.join(appRoot, "resources", "app", "dsh", "node_modules", "@deepseek-ai");

function patchFile(file, fn) {
  if (!fs.existsSync(file)) {
    throw new Error(`missing host file: ${file}`);
  }
  const before = fs.readFileSync(file, "utf8");
  const after = fn(before);
  if (after === before) return false;
  fs.writeFileSync(file, after, "utf8");
  return true;
}

function patchFsObservation(text) {
  if (text.includes("// [dsh-purge] observation bypass: edits are unconditional (no read-first gate).")) return text;
  const re = /^([\t ]*)editIntent\(target, actor\) \{\n[\t ]*return this\.requirePresent\(target, actor, "edit"\);\n[\t ]*\}/m;
  const match = text.match(re);
  if (!match) throw new Error("patch 17 anchor not found");
  const indent = match[1];
  return text.replace(re, `${indent}editIntent(target, actor) {\n${indent}\t// [dsh-purge] observation bypass: edits are unconditional (no read-first gate).\n${indent}\treturn void 0;\n${indent}}`);
}

function patchAgentLoop(text) {
  if (text.includes("[dsh-purge] prepare assemble before this step")) return text;
  const re = /^([\t ]*)const assembly = await this\.loopCtx\.systemPrompt\.assemble\(\{/m;
  const match = text.match(re);
  if (!match) throw new Error("patch 74 anchor not found");
  const indent = match[1];
  return text.replace(re, `${indent}const dshPurgePrepare = globalThis.__dshPurgePrepareAssemble;\n${indent}if (typeof dshPurgePrepare === "function") {\n${indent}\ttry { dshPurgePrepare(this.loopCtx); } catch { /* [dsh-purge] prepare assemble before this step */ }\n${indent}}\n${indent}const assembly = await this.loopCtx.systemPrompt.assemble({`);
}

function patchSystemPrompt(text) {
  if (text.includes("[dsh-purge] complete prompt keeps inject + agent-instructions")) return text;
  const startMarker = '\t\tconst transformed = await this.ctx.waterfall(scopeTarget(this, scope), "system-prompt/assemble", assembly, context, () => Promise.resolve(assembly));';
  const start = text.indexOf(startMarker);
  if (start < 0) throw new Error("patch 40 block start not found");
  const tailMarker = "\n\t\t\tcontexts: runtimeContextSuppressed ? transformed.contexts.filter((entry) => requiredContexts.has(entry.name)) : transformed.contexts\n\t\t};";
  const tail = text.indexOf(tailMarker, start);
  if (tail < 0) throw new Error("patch 40 block tail not found");
  const block = `\t\tconst transformed = await this.ctx.waterfall(scopeTarget(this, scope), "system-prompt/assemble", assembly, context, () => Promise.resolve(assembly));
\t\tconst dshPurgeSections = (transformed.sections || []).filter((s) => String(s && s.name || "").startsWith("dsh-purge") && String(s.text || "").length > 0);
\t\tconst dshPurgeRest = (transformed.sections || []).filter((s) => !String(s && s.name || "").startsWith("dsh-purge"));
\t\tif (completeSection === void 0 && !runtimeContextSuppressed) return {
\t\t\t...transformed,
\t\t\ttools
\t\t};
\t\tconst requiredContexts = new Set([...contextByName.values()].filter((entry) => entry.required === true).map((entry) => entry.name));
\t\treturn {
\t\t\t...transformed,
\t\t\ttools,
\t\t\tsections: completeSection === void 0 ? transformed.sections : (function (complete, purge, rest) {
\t\t\t\tconst base = { ...complete };
\t\t\t\tconst tail = rest.filter((s) => String(s?.name || "") !== String(base.name || ""));
\t\t\t\treturn [...purge, ...tail, base]; // [dsh-purge] complete prompt keeps inject + agent-instructions
\t\t\t})(completeSection, dshPurgeSections, dshPurgeRest),
\t\t\tcontexts: runtimeContextSuppressed ? transformed.contexts.filter((entry) => requiredContexts.has(entry.name)) : transformed.contexts
\t\t};`;
  return text.slice(0, start) + block + text.slice(tail + tailMarker.length);
}

const changed = [];
if (patchFile(path.join(root, "dsh-fs-observation-policy", "lib", "index.js"), patchFsObservation)) changed.push("17");
if (patchFile(path.join(root, "dsh-agent-loop", "lib", "index.js"), patchAgentLoop)) changed.push("74");
if (patchFile(path.join(root, "dsh-system-prompt", "lib", "index.js"), patchSystemPrompt)) changed.push("40");
console.log(`host compatibility patches applied: ${changed.length ? changed.join(", ") : "already present"}`);
