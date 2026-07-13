# Workflow: Creating Architecture Diagrams

Team workflow for creating and reviewing Mermaid architecture diagrams in this
repo (README, docs). Not a user-facing tutorial: a checklist for contributors
and agents.

## When to diagram

**One diagram = one message.** Stop when a second concern appears:

| Concern | Use | README placement |
|---------|-----|------------------|
| Who talks to whom at system scope | System context diagram | Architecture |
| How one request flows through plugins | Request path diagram | Plugins |
| Where usage/request logs land after upstream responds | Telemetry and logging diagram | Configuration (ClickHouse Tables) |
| Metrics scrape and dashboard queries | Metrics and dashboards diagram | Configuration (Grafana Dashboards) |
| Route templates, etcd, Admin API | Control plane diagram | Configuration (Routes and config) |
| Auth or key decision logic | Decision flow diagram | Key Management |
| Which routes/upstreams ship in this repo | Sample deployments table | Architecture |

If you need two messages, use two diagrams (or diagram + table). Do not merge
context, deployment, data flow, and observability on one canvas.

## Placement: distribute, do not clump

Diagrams belong in the **section that owns the concern**, immediately before or
after the prose/tables they illustrate. Readers should encounter the diagram
while reading about that topic, not in a single "diagram gallery" block.

| Do | Don't |
|----|-------|
| Put request-path diagram under **Plugins** | Stack Diagrams 1-5 under **Architecture** |
| Put telemetry diagram above the ClickHouse table it explains | Repeat every flow in Architecture "How it works" |
| Put metrics diagram in **Grafana Dashboards** | Number diagrams globally (Diagram 1, 2, 3...) across the doc |
| One document-wide legend at the first diagram | Repeat the legend before every diagram |

Cross-link from Architecture with a short pointer list to section anchors
(`#plugins`, `#configuration`, `#key-management`), not a diagram inventory.

## Diagram types we use

Mapped to [C4](https://c4model.com/) and
[Azure WAF design diagrams](https://learn.microsoft.com/en-us/azure/well-architected/architect-role/design-diagrams).

### System context (C4 level 1)

- **Audience:** anyone opening the repo
- **Nodes:** clients, gateway box, external providers/storage
- **Exclude:** plugin names, etcd, Vector, Grafana, route prefixes
- **Budget:** ≤7 nodes

Example: README **Architecture / System context**.

### Request path

- **Audience:** implementers
- **Message:** single happy-path spine for **one** route prefix
- **Include:** plugin phases only when showing one federated/cloud path
- **Exclude:** telemetry sinks (ClickHouse, Vector), Grafana, etcd
- **Budget:** ≤7 nodes
- **Caption:** note how other prefixes differ (e.g. skip `key-resolver`)

Example: README **Plugins / Request path**.

### Telemetry and logging

- **Audience:** implementers tracing usage or request logs
- **Message:** response-phase plugins to storage (one path per sink)
- **Start from:** upstream response or telemetry plugin node, not the client
- **Budget:** ≤6 nodes
- **Keep separate** from the request-path diagram (never extend the request
  spine with Vector/ClickHouse branches)

Example: README **Configuration / ClickHouse Tables**.

### Metrics and dashboards

- **Audience:** operators and dashboard authors
- **Message:** export path (plugin to `:9100` to Prometheus) and read paths (Grafana queries)
- **Exclude:** request routing, Vector ingest, etcd
- **Budget:** ≤6 nodes
- **Grafana to ClickHouse:** dashed, labeled `SQL queries` or `queries`; never solid write

Example: README **Configuration / Grafana Dashboards**.

### Control plane

- **Audience:** deployers and route editors
- **Message:** template render to seed to etcd to live routes
- **Include:** Admin API as dashed sidecar to etcd (not on the request path)
- **Exclude:** LLM upstreams, telemetry sinks, Grafana
- **Budget:** ≤7 nodes

Example: README **Configuration / Routes and config**.

### Decision flow

- **Audience:** implementers debugging auth or policy
- **Layout:** top-to-bottom with converging branches (one outcome node)
- **Use edge labels** for route-specific behavior, not duplicate nodes

Example: README **Key Management**.

### Sample deployments

- **Format:** markdown table, not a diagram
- **Title:** `Sample deployments in this repo` (not "Current deployment")
- **Column:** `Sample upstream` (not "Upstream today")
- **Prose:** sample framing, e.g. "In this sample, ..." not "currently the only ..."

## Layout rules (Mermaid)

1. Prefer `flowchart TB` with a **single downward spine** (top to bottom reading).
2. **Avoid fan-out:** do not connect one node to 3+ siblings then merge (spider).
3. Group peers with `subgraph` + `direction LR` only at the same tier.
4. **Orphan nodes float**: attach sidecars with dashed edges or put them in a subgraph.
5. Do **not** rely on ELK/tidy-tree `%%{init}%%`; GitHub README renderer may ignore it.
6. Western reading order: declare nodes in the order you want the story told.

### Reliable spine pattern

```mermaid
flowchart TB
    A --> B --> C --> D
    D -->|labeled edge| E
    Sidecar[(Sidecar)] -.->|dashed| B
```

Not:

```mermaid
flowchart TB
    A --> B & C & D
    B & C & D --> E
```

## Arrow semantics

| Style | Meaning |
|-------|---------|
| Solid `-->` | Runtime request/response or data **write** path |
| Dashed `-.->` | Config, key lookup, control plane, **read-only** queries |

Rules:

- Label non-obvious edges (`usage_log`, `request_log`, `vgw-* keys`, `queries`).
- No bidirectional arrows.
- **Grafana to ClickHouse** is a read/query path: dashed, labeled `queries`, not a solid write.
- Prefer two one-way arrows over double-headed lines.

When mixing solid and dashed in one diagram, add a short **legend** once at the
first diagram in the document (see README Architecture).

## Gateway-specific conventions

- Gateway is **provider-agnostic** in context diagrams. List OpenCode, xAI, etc.
  in sample deployment tables, not as the only upstream node in a context box.
- Plugin names belong in request-path diagrams or prose, not the context diagram.
- Routes `/opencode*`, `/llamafile/*` are **examples shipped in this repo**, not
  product identity. Additional providers = new relay route + upstream node.
- OpenCode is a valid **sample upstream** in tables; it must not headline the
  gateway as "the OpenCode gateway" in diagrams.

## Mermaid and markdown hygiene

Lessons from broken or rejected diagram edits:

| Issue | Fix |
|-------|-----|
| Empty diagram in preview | Verify opening ` ```mermaid ` and closing ` ``` ` are on **their own lines** with no extra backticks inside the block |
| Nested backticks in assistant/chat citations | Never wrap a mermaid block inside another fenced code block when editing |
| Unicode em-dash (U+2014) or en-dash (U+2013) | CI `check-banned-words` rejects them; use `:`, `,`, or ASCII `-` |
| Request path + telemetry on one canvas | Split: request spine ends at upstream; telemetry starts at upstream response |
| Prometheus/Grafana only in prose | Add metrics diagram in Grafana section; do not stuff into context diagram |
| etcd/Admin API only in prose | Add control-plane diagram in Configuration section |

Validate fence pairing after edits: count ` ```mermaid ` open/close pairs in
the edited file (each block must end with a lone ` ``` ` line on its own).
Preview at [mermaid.live](https://mermaid.live) or GitHub before merge.

## Pre-merge checklist

- [ ] Diagram sits in the section that owns the concern (not clumped in Architecture)
- [ ] Diagram type matches audience (context vs path vs decision)
- [ ] Single spine; no spider fan-in/out
- [ ] Request path and telemetry are separate diagrams
- [ ] Arrow direction matches real data flow (writes solid, reads/config dashed)
- [ ] Legend present once if mixing solid and dashed
- [ ] Node count within budget (≤7 context/path/control, ≤6 telemetry/metrics)
- [ ] Rendered at [mermaid.live](https://mermaid.live) or GitHub preview (non-empty)
- [ ] Prose cross-links sections; no global "Diagram 1 = ... Diagram 5 = ..." laundry list
- [ ] No Unicode em-dash or en-dash in edited markdown
- [ ] `make check` / markdown link checks pass

## References

- [Azure WAF: Design diagrams](https://learn.microsoft.com/en-us/azure/well-architected/architect-role/design-diagrams)
- [C4 model](https://c4model.com/)
- [Mermaid flowchart syntax](https://mermaid.js.org/syntax/flowchart.html)
- In-repo: [`docs/DASHBOARD-REQUIREMENTS.md`](../docs/DASHBOARD-REQUIREMENTS.md): Grafana panel specs (different concern; do not mix into gateway context diagrams)
- In-repo: [`docs/architecture/README.md`](../docs/architecture/README.md): architecture hub; see architecture/RUNTIME-TOPOLOGY.md

## Anti-patterns (from past README mistakes)

| Anti-pattern | Fix |
|--------------|-----|
| All flow diagrams under Architecture | Distribute to Plugins, Configuration, Key Management |
| Numbered diagram gallery (Diagram 1-5) | Descriptive headings in owning sections |
| One canvas with routes + plugins + etcd + Vector + Grafana | Split into context + request + telemetry + metrics + control plane |
| Request path diagram includes ClickHouse/Vector branches | Request path in Plugins; telemetry in Configuration |
| etcd/Prometheus only mentioned in prose | Control plane and metrics diagrams in Configuration |
| Naming one vendor as the headline upstream in a multi-provider gateway doc | Generic "Cloud LLM APIs" node; vendor in sample table |
| `### Current deployment (this repo)` | `### Sample deployments in this repo` |
| `Upstream today` column | `Sample upstream` |
| `Grafana --> ClickHouse` solid arrow | Dashed `-.->|SQL queries|` |
| Three route nodes fanning from Clients | One route in request-path diagram; others in table |
| Floating etcd/OpenBao between subgraphs | Dashed edge from gateway or dedicated control-plane diagram |
| "How it works" re-narrates every arrow | Short cross-links to section anchors |