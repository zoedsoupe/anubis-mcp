# Protocol support

Anubis has two independent support axes:

1. **Protocol revisions**: which MCP versions the protocol registry can recognize and negotiate.
2. **Behavioral coverage**: which client and server capabilities are implemented for each revision.

A registered dialect is not, by itself, a claim of complete behavioral support. Optional capabilities, transport bindings, authorization, deprecated features, and extensions have separate obligations and coverage.

> **Audit basis:** this page describes the Anubis 2.2.0 source at commit `df5091e`, statically audited on 2026-11-19 against the official MCP specifications. The 1.x column records confirmed inherited gaps, not a complete audit of the 1.14.0 source. See [Measuring conformance](#measuring-conformance) before interpreting these results as compliance claims.

Follow the actionable version of this audit in [#342: Protocol support and official conformance roadmap](https://github.com/zoedsoupe/anubis-mcp/issues/342).

## Release lines and protocol revisions

| Anubis release | Release policy | MCP revisions recognized by the dialect registry |
| --- | --- | --- |
| 1.x | Maintenance of already-recognized revisions | 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25 |
| 2.x | Active development, new revisions, features, and extensions | 2025-03-26, 2025-06-18, 2025-11-25, 2026-07-28 |

Anubis 2.0 removed support for MCP 2024-11-05 and the deprecated HTTP+SSE transport. Dropping a protocol revision remains a major-version change.

## Status vocabulary

| Status | Meaning |
| --- | --- |
| **Tested** | Local tests exercise the named behavior. This does not mean the whole capability is conformant or that an official conformance scenario passes. |
| **Partial** | Some useful behavior exists, but one or more named obligations or workflows are missing or defective. |
| **Missing** | The workflow is not implemented. |
| **Not adopted** | An optional feature that the SDK currently does not provide. This is not automatically a core protocol violation. |
| **N/A** | The requirement does not apply to that role, transport, or protocol revision. |
| **Unaudited** | There is not enough evidence to publish a stronger status. |

## Anubis 2.x: MCP 2026-07-28 coverage

The 2026 revision replaces the initialize handshake and protocol sessions with stateless requests carrying per-request metadata. Server-initiated requests are replaced by Multi Round-Trip Requests (MRTR). Tasks move out of core into an extension.

### Core protocol and capabilities

| Capability | Client | Server | Known limitations and evidence |
| --- | --- | --- | --- |
| Era detection and `server/discover` | **Partial** | **Partial** | Discovery, era detection, metadata, and decoded `-32022` retries have local tests. Ordinary HTTP non-2xx error bodies can hide `-32022`; dual-era routing and discovery diagnostics have edge cases. |
| Per-request metadata and identity | **Tested** | **Partial** | Version and capabilities are sent per request, and server admission is tested over HTTP. Stateless STDIO session isolation is not sufficiently tested. |
| Result envelopes and `resultType` | **Partial** | **Partial** | Dialect schemas model `complete` and `input_required`. The client does not validate or dispatch on `resultType`; custom server responses do not pass through a universal outbound conformance gate. |
| MRTR: retries, `inputResponses`, and opaque `requestState` | **Missing** | **Partial** | Tracked in [#332](https://github.com/zoedsoupe/anubis-mcp/issues/332). The server implements signed state and core MRTR flows; the client returns `input_required` as an ordinary result. URL-mode elicitation helpers are incomplete. |
| Tools | **Partial** | **Tested** | List/call and output-schema behavior have local coverage. Client header mirroring and complete structured-content validation remain partial; see transport and MRTR rows. |
| Resources | **Partial** | **Tested** | Core list/read/templates behavior has local coverage. Client MRTR and transport limitations still apply. |
| Prompts | **Partial** | **Tested** | Core list/get behavior has local coverage. Client MRTR limitations still apply. |
| `subscriptions/listen` and notification demultiplexing | **Missing** | **Partial** | Tracked in [#332](https://github.com/zoedsoupe/anubis-mcp/issues/332). HTTP server streams are tested; the client has no public listen API, and STDIO server streams are missing. |
| Cancellation and progress | **Partial** | **Partial** | Buffered HTTP client responses delay progress and block useful cancellation. Current HTTP cancellation uses response-stream closure rather than the legacy notification, which is not expected there and cannot interrupt the buffered request. Server cancellation and STDIO dispatch have edge cases. |
| Pagination and response caching | **Partial** | **Partial** | Manual cursor pagination exists. Client response caching with `ttlMs`/`cacheScope` is **Not adopted**, and is optional behavior rather than a required cache. Server cache hints exist; invalid cursors and some cache cases need correction or tests. |
| Completion | **Tested** | **Partial** | The server advertises `completion` instead of the specified `completions` capability key. |
| Per-request logging | **Missing** | **Partial** | The client has no per-request `logLevel` option and overwrites caller-provided stateless metadata. Server request-scoped gating needs additional cases. Logging is deprecated upstream but remains specified in this revision. |
| Roots | **Missing** | **Tested** | Current roots require MRTR. Legacy local roots and `roots/list` responses exist. Roots are deprecated upstream. |
| Sampling | **Partial** | **Partial** | Legacy text/media flows exist. Tool-enabled results are rejected by an inherited schema, and current sampling requires MRTR. Sampling is deprecated upstream. |
| Elicitation | **Partial** | **Partial** | Legacy form and URL flows have substantial coverage. Current flows depend on missing client MRTR support; URL-mode helpers are incomplete, and mode-mismatch errors need correction. |
| Extensions | **Partial** | **Partial** | Capability maps can carry extension identifiers, but negotiation, method dispatch, and result handling do not yet form a complete extension boundary. Actual extensions are listed separately below. |

### Transports and authorization

| Surface | Client | Server | Known limitations |
| --- | --- | --- | --- |
| STDIO | **Partial** | **Partial** | Basic framing and dual-era behavior exist. Current subscriptions and some notification/cancellation paths are missing on the server; current client subscriptions are missing. |
| Streamable HTTP | **Partial** | **Partial** | The client buffers complete responses and lacks incremental request-stream handling. The server lacks mandatory Origin validation, tracked in [#338](https://github.com/zoedsoupe/anubis-mcp/issues/338), and has legacy/current boundary defects. Legacy session IDs require cryptographically secure generation; session-fixation impact remains unverified. |
| Standard and custom HTTP headers | **Partial** | **Tested** | `MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name` exist. Client `Mcp-Param-*` extraction, invalid-tool filtering, and header-mismatch recovery are missing; tracked in [#332](https://github.com/zoedsoupe/anubis-mcp/issues/332). |
| Authorization | **Partial** | **Partial** | Client support currently focuses on authorization metadata discovery, not a complete OAuth grant and credential lifecycle. Resource-server token validation exists, but challenge construction and HTTP status mapping have gaps. Insufficient-scope failures can become a JSON-RPC error over HTTP 200 instead of the required 403. Related builder gaps are tracked in [#338](https://github.com/zoedsoupe/anubis-mcp/issues/338), and OIDC/CIMD work in [#261](https://github.com/zoedsoupe/anubis-mcp/issues/261). |

`Origin` validation is a server obligation. It is not marked as a client gap. Authorization is optional in MCP, but its normative requirements apply when the corresponding behavior is implemented.

## Legacy revision coverage in Anubis 2.x

The legacy revisions share the initialize/session model but are not interchangeable parameter sets. Their transports, authorization requirements, and feature surfaces differ.

| MCP revision | Coverage | Important distinctions and audited gaps |
| --- | --- | --- |
| 2025-03-26 | **Partial** | Streamable HTTP and OAuth metadata generation. This revision permits JSON-RPC batching, but the current server rejects batch requests. Other requirements remain only partially audited. |
| 2025-06-18 | **Partial** | Adds structured tool output and form elicitation; removes batching; strengthens authorization and the protocol-version header. Known completion-capability and authorization-response gaps apply. |
| 2025-11-25 | **Partial** | Adds sampling tools, URL elicitation, OIDC discovery/CIMD, experimental tasks, and JSON Schema 2020-12 defaults. Sampling results, client tasks, and some authorization/error behaviors have known gaps. |
| 2024-11-05 | **N/A in 2.x** | Removed in Anubis 2.0 together with HTTP+SSE. It remains recognized by the 1.x maintenance line. |

MCP 2025-11-25 tasks are experimental core protocol. In MCP 2026-07-28 they are replaced by the separate Tasks extension; these are different protocol surfaces and should not share one compliance checkbox.

## Anubis 1.x maintenance scope

The last published 1.x release is 1.14.0. A complete historical coverage matrix is **Unaudited**. Static comparison already confirms:

- tool-enabled sampling results have the same schema limitation tracked in [#259](https://github.com/zoedsoupe/anubis-mcp/issues/259);
- the client has no public API for the experimental 2025-11-25 tasks surface tracked in [#260](https://github.com/zoedsoupe/anubis-mcp/issues/260);
- the legacy Streamable HTTP scenario in [#238](https://github.com/zoedsoupe/anubis-mcp/issues/238) requires reproduction and a version-scoped fix, not an assertion that the same failure still exists on every release;
- the Origin and authorization-challenge requirements in [#338](https://github.com/zoedsoupe/anubis-mcp/issues/338) also apply to parts of the 1.x matrix, subject to their exact protocol-revision boundaries.

The `release/1.x` branch is for security fixes, bug fixes, and non-breaking compliance repairs for revisions that 1.x already recognizes. New protocol revisions and optional extensions do not automatically belong in that line. A larger feature backport may require a 1.x minor release rather than being presented as a patch.

## Extension coverage

Extensions are optional, disabled by default, and do not count toward core protocol conformance. Support must include explicit opt-in and graceful behavior when the peer does not advertise the same extension.

| Extension | Client | Server | Tracking |
| --- | --- | --- | --- |
| Tasks, `io.modelcontextprotocol/tasks` | **Missing** | **Missing** for 2026-07-28 | The 2025 experimental core implementation must not be mistaken for the 2026 extension. Related work: [#260](https://github.com/zoedsoupe/anubis-mcp/issues/260). |
| MCP Apps, `io.modelcontextprotocol/ui` | **Not adopted** | **Partial** | Server-side metadata and UI resource surface exist; there is no native client UI lifecycle. Feature request: [#278](https://github.com/zoedsoupe/anubis-mcp/issues/278). |
| Skills, Server Cards, and authorization extensions | **Not adopted** | **Not adopted** | No conformance claim is made. |

## Open-issue protocol applicability

| Issue | Protocol scope | 1.x applicability |
| --- | --- | --- |
| [#238](https://github.com/zoedsoupe/anubis-mcp/issues/238) | Legacy Streamable HTTP session/SSE behavior, from 2025-03-26 onward | Potentially applicable after reproduction; not applicable to the current stateless era |
| [#259](https://github.com/zoedsoupe/anubis-mcp/issues/259) | Sampling tools introduced in 2025-11-25; payload persists in 2026, but MRTR replaces direct server-initiated delivery | Applicable as version-gated 2025-11-25 support; implementation cannot simply be reused for 2026 |
| [#260](https://github.com/zoedsoupe/anubis-mcp/issues/260) | Experimental core tasks in 2025-11-25; different Tasks extension in 2026 | The confirmed client gap is applicable; core and extension work must be scoped separately |
| [#261](https://github.com/zoedsoupe/anubis-mcp/issues/261) | OIDC discovery and CIMD introduced in 2025-11-25 | Requires role and scope triage: resource-server, authorization-server, and OAuth-client duties are not interchangeable |
| [#332](https://github.com/zoedsoupe/anubis-mcp/issues/332) | `subscriptions/listen`, MRTR, and `Mcp-Param-*`, all introduced in 2026-07-28 | **N/A** |
| [#278](https://github.com/zoedsoupe/anubis-mcp/issues/278) | Stable MCP Apps extension | Optional additive work, not a core compliance backport |
| [#338](https://github.com/zoedsoupe/anubis-mcp/issues/338) | Origin validation applies across HTTP revisions; `WWW-Authenticate` obligations begin in 2025-06-18 | Applicable within those exact revision boundaries; excluded from the current implementation batch but retained in the support audit |

## Measuring conformance

Anubis does not currently publish results from the official [MCP conformance suite](https://github.com/modelcontextprotocol/conformance). The local test audit above is not a substitute for that suite, and this page does not assign an SDK tier.

The useful next step is to add thin conformance runners for the Anubis client and server, then publish independently measured client/server results for:

- [MCP 2026-07-28 requirements](https://github.com/modelcontextprotocol/conformance/blob/main/requirements/2026-07-28.yaml);
- [MCP 2025-11-25 requirements](https://github.com/modelcontextprotocol/conformance/blob/main/requirements/2025-11-25.yaml).

The suite supports frozen per-revision requirements, wire-schema checks, and per-check expected-failure baselines. A baseline can document known failures without hiding new regressions; a passing previously-baselined check must be promoted back to required. Results should be produced in CI for both roles and attached as inspectable artifacts.

The official [SDK tier criteria](https://modelcontextprotocol.io/community/sdk-tiers) also cover maintenance, triage, releases, documentation, dependency policy, and roadmap. Conformance percentages alone are not a tier claim.

Older 1.x revisions still need their applicable legacy and backward-compatibility scenarios; the two frozen requirement sets above do not prove complete support for 2024-11-05, 2025-03-26, or 2025-06-18.

## Sources and update policy

Normative coverage was mapped from the official specifications:

- [2024-11-05](https://modelcontextprotocol.io/specification/2024-11-05/index)
- [2025-03-26](https://modelcontextprotocol.io/specification/2025-03-26/index)
- [2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/index)
- [2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/index)
- [2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/index) and its [changelog](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
- [Extensions](https://modelcontextprotocol.io/extensions/overview)
- [Feature lifecycle and deprecation](https://modelcontextprotocol.io/community/feature-lifecycle)
- [Current deprecated-feature registry](https://modelcontextprotocol.io/specification/2026-07-28/deprecated)

Update this page when a capability changes, linking the corresponding test or issue. Do not promote a row from **Partial** to **Tested** because a schema was added: the relevant client/server behavior must also have test evidence. Replace static audit results with official conformance results only for scenarios actually executed at the claimed wire revision.
