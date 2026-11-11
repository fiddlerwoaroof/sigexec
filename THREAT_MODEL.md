# Threat model: capability broker for agent credentials

Status: **design target**. This document defines what the broker must
guarantee and under which deployment conditions. sigexec today is the
transport substrate (Unix socket + `SCM_RIGHTS`), not the broker; see
[Current sigexec vs. this model](#current-sigexec-vs-this-model).

## 1. Purpose

Let agent processes use network services (Atlassian first) that require
long-lived credentials, without ever giving the agent those credentials and
without granting authority by identity (uid, path permissions, ACLs).
Authority is conveyed only by possession of a capability, which the agent
obtains through a human-approved request.

Process isolation (separate uids, Seatbelt, VMs) is built separately. This
document states what that isolation must provide (§7) for each guarantee to
hold.

## 2. System model

| Component | Role |
|---|---|
| **Broker** | Long-running process. Holds the credentials, the policy, and the broker-side end of every capability. Makes all upstream connections. |
| **Powerbox endpoint** | A named Unix socket served by the broker. Its only power is to *request* a capability. |
| **Approver** | UI in the human's session. Renders a grant for approval and returns an approval bound to that grant. |
| **Capability** | A file descriptor: one end of a socketpair whose other end the broker holds, bound to a fixed scope (§2.1). |
| **Policy** | Broker-owned config: the capability types, their scopes, and their approval requirements. |
| **Secret store** | Credentials at rest, encrypted under a key the adversary can't use (§5). |
| **Upstream** | The network service (e.g. `api.atlassian.com`). |

Flow:

1. The agent connects to the powerbox and requests a capability type from
   the policy (e.g. `jira:read`) with parameters. It may attach a
   justification.
2. The broker parses the request against the policy and generates the
   approval text itself. Any agent-supplied justification is shown separately
   and labeled as agent-supplied.
3. The approver obtains a human decision bound to (grant, nonce).
4. If approved, the broker returns an fd over the powerbox connection. The
   reply carries a fixed-format status and the fd, nothing else.
5. The agent speaks HTTP/1.1 on the fd. For each request, the broker checks
   it against the capability's scope, removes any agent-supplied
   credentials, adds the real credential on its own TLS connection to the
   fixed upstream origin, and relays the filtered response (§6).

### 2.1 Capability scope

A scope consists of a fixed upstream origin (scheme, host, port), an
allowlist of methods and normalized paths, an expiry, a request budget, and
an optional body-size limit. Scopes form a partial order. **Attenuation**
(exchanging a capability for a narrower one) only moves down that order.

### 2.2 Capability operations

- **Use:** read/write on the fd.
- **Delegate:** pass the fd to another process (inheritance or
  `SCM_RIGHTS`). Delegation is intended. Accidental delegation is a hazard
  (§9).
- **Attenuate:** present the fd to the broker over the powerbox and receive a
  narrower one. The broker must verify that the presented fd really is one of
  its endpoints, e.g. by a round trip through it, not by trusting a claimed
  ID.
- **Revoke:** the broker closes its end. The next operation on the fd fails.
  Expiry and an exhausted budget revoke automatically.

## 3. Assets

1. **Long-lived credentials** (API tokens, signing keys). Highest value:
   possession grants authority outside every scope, beyond any expiry, and
   off-host.
2. **Authority to act** on upstream services within some scope.
3. **Integrity of approvals:** the human's decisions.
4. **Broker logs**, which record grants and requests and may contain service
   data.

## 4. Adversary

The adversary is arbitrary code in the agent's process tree, including code
written by a prompt-injected model. It can:

- execute arbitrary programs and system calls as the agent's uid;
- read and write anything that uid can, including the user's files when the
  agent runs as the user;
- connect to any socket that uid can reach, including the powerbox;
- send arbitrary bytes on any capability it holds, including malformed or
  ambiguous HTTP;
- request capabilities at any rate, with any justification text;
- delegate capabilities among its own processes.

Out of scope as adversaries: root, the kernel, firmware, anyone with
physical access, the human operator, and the upstream service.

## 5. Trusted computing base

- The broker binary and its policy.
- The approver binary and its signing key (if approvals are signed).
- The secret-store key: e.g. a gpg key owned by the broker's uid
  (optionally on a token with a touch policy), or an SEP key requiring user
  presence held by the approver.
- The OS kernel (fd semantics, socket credentials, uid separation) and, on
  macOS, the Secure Enclave and LocalAuthentication.
- In script mode only (§6.2), every script the broker runs.

## 6. Guarantees

Each guarantee holds under the deployment conditions in §7.

**G1 — Credential confidentiality.** Credential bytes never enter an address
space, fd, file, or environment the adversary can read. The broker never
writes them to any agent-facing channel.

**G2 — No ambient authority.** Every action on an upstream is done through a
capability. A uid, a path, or the ability to connect to the powerbox
conveys only the right to *request* a capability.

**G3 — Scope confinement.** A capability can only cause upstream requests
inside its scope. Its scope never widens. In particular, the agent can't
change the origin, so the credential can't be sent anywhere else.

**G4 — Approval integrity.** Every grant corresponds to one human approval of
text the broker rendered from that exact grant. Approvals are single-use,
bound to a nonce, and can't be replayed or transferred to a different grant.

**G5 — Revocability.** After revocation, expiry, or budget exhaustion, no
further upstream request is made on that capability.

**G6 — No derived credentials.** The agent never receives credentials the
upstream issues in response to the broker's authentication. The broker
strips `Set-Cookie`, `Authorization`-style response headers, and any
headers the policy names, and never follows redirects.

**G7 — Accountability.** Every grant, approval, and upstream request is
recorded in a log the adversary can't read or modify. The log never
contains credential bytes.

### 6.1 Request handling (enforces G3 and G6)

- **HTTP/1.1 only.** Reject `CONNECT`, `Upgrade`, HTTP/2 prefaces,
  absolute-form and authority-form request targets, and any message whose
  framing is ambiguous (both `Content-Length` and `Transfer-Encoding`,
  duplicate `Content-Length`, obsolete line folding).
- **Normalize before matching.** Decode percent-encoding once, remove dot
  segments, and reject encoded slashes and NULs. Match the normalized path
  against the allowlist; forward the normalized form.
- **Overwrite or strip** `Host`, `Authorization`, `Cookie`,
  `Proxy-Authorization`, and hop-by-hop headers from the agent.
- **Responses:** relay the status and body. Drop `Set-Cookie` and
  policy-named headers. Don't follow 3xx; relay them as-is (the agent can't
  follow them off-origin through this capability anyway).
- **Redaction backstop:** before relaying, the broker scans for exact matches
  of every credential it holds and its known encodings (raw,
  `base64(user:token)`). This is defense in depth, not a guarantee (§9).

### 6.2 Script mode (compatibility, weaker)

For operations that aren't HTTP, the broker can run a fixed program
(sigexec style). In this mode **G1 depends on every script being correct.**
Scripts are in the TCB. The output rules are strict:

- The child's stdout and stderr go to a broker-private log, never to the
  agent. (This also catches `set -x`: xtrace goes to stderr or
  `BASH_XTRACEFD`.)
- The only result channel is an opt-in typed one: the script writes to fd 3,
  and the broker parses that against a declared schema with a size limit,
  applies the redaction backstop, and relays only what parses.
- The agent's input is untrusted data. It is passed as argv without a shell,
  and scripts must not interpret it as code, a URL, or a host.
- The program is identified by an absolute, immutable path (e.g. in
  `/nix/store`), never resolved via `PATH`.
- Children receive only fds 0–2 and fd 3. Everything else is closed at
  spawn (`POSIX_SPAWN_CLOEXEC_DEFAULT` on Darwin, `close_range` on Linux).

## 7. Deployment profiles

The guarantees depend on what the OS-level isolation provides. Three
profiles:

| | D0: all one uid | D1: separate broker uid | D2: agent uid ≠ human uid ≠ broker uid, or agent in a VM |
|---|---|---|---|
| G1 | **No** | Yes, with conditions | Yes |
| G2, G3, G5, G6 | Only against non-malicious misuse | Yes | Yes |
| G4 | **No** | Conditional | Yes |
| G7 | No | Yes | Yes |

**D0** is useful against *accidents* (an agent printing its environment)
but not against an active adversary. The agent can read the secret store or
use a cached gpg-agent passphrase, read child environments (`ps -E`,
`/proc/PID/environ`), modify the broker or its user-writable launchd plist,
and run a fake broker that gets a real Touch ID approval.

**D1** requires:

- secrets at rest owned by and decryptable only by the broker uid;
- the broker binary, policy, and launchd plist not writable by the agent
  uid (root-owned, e.g. `/Library/LaunchDaemons`);
- the powerbox socket in a directory the agent uid can connect into but not
  replace.

G4 in D1 is weaker because the approver runs in the human's session, which
is the same uid as the agent. It holds only if the approval is
unforgeable *and* bound to the approver's code identity. For example: an SEP
signing key requiring biometry, stored in a keychain access group of the
team-signed approver, and verified by the broker against a pinned public key.
A loose SEP `dataRepresentation` file doesn't meet this. It is bound to the
device and user, not to the code, so a fake approver running as the same uid
could get a real touch for a different grant.

**D2** separates the agent from the human's uid (or puts it in a VM with
the powerbox exposed over vsock). The approver and secret store are then out
of the adversary's reach and every guarantee holds.

## 8. Capability representations

- **fd capability (primary).** Unforgeable, delegable only through kernel
  fd transfer, and not leaked by printing or logging. Requires fd-aware
  clients or a shim that inherits the fd.
- **Sparse capability (compatibility, weaker).** A localhost URL containing
  ≥128 random bits. Possession of the *string* is authority, so it leaks the
  way the original credential did (environment, logs, argv). G2 weakens to
  "authority by knowledge of an unguessable name". The damage is bounded by
  scope, expiry, budget, and local-only reachability. Use only when an fd
  can't be delivered, and say so in the grant text.

## 9. Residual risks

- **Upstream reflection.** An upstream that echoes request headers (debug
  endpoints, some error pages) could return the credential. The redaction
  backstop catches only exact known encodings, not partial or transformed
  copies.
- **Parser differentials.** If the broker and the upstream parse a request
  differently, scope checks can be bypassed. Mitigated by §6.1's
  reject-if-ambiguous rules and a single, strict parser.
- **Accidental delegation.** An fd without close-on-exec is inherited by
  every child. Darwin has no `MSG_CMSG_CLOEXEC`, so fds received over
  `SCM_RIGHTS` must be marked `FD_CLOEXEC` immediately; there is a window
  before that.
- **Prompt fatigue.** An agent can request repeatedly until a tired human
  approves. Rate limits and batching mitigate this; nothing guarantees
  against it.
- **Human error.** Approving a grant that is too broad.

## 10. Non-goals

- Preventing exfiltration of data a capability legitimately returns. That
  requires egress control on the agent.
- Preventing misuse inside a granted scope (confused deputy within scope).
- Covert and timing channels.
- Availability: the adversary can flood the powerbox or exhaust budgets.
- Compromised upstreams, root, the kernel, or physical attackers.

## 11. Open questions

1. How a presented fd is identified for attenuation (round-trip challenge
   vs. kernel facilities such as `kcmp` on Linux).
2. Whether approvals can cover a short-lived *batch* of grants (e.g.
   LocalAuthentication's reuse window) without weakening G4.
3. Streaming responses and large bodies: redaction needs buffering or a
   streaming matcher that handles matches split across chunks.
4. Policy reload semantics: does a reload narrow live capabilities, or apply
   only to new grants?

## Current sigexec vs. this model

sigexec provides the transport and fd passing. As a broker it currently
falls short in these ways:

- **The socket path is the authority.** Anyone who can connect triggers the
  command. Under this model the named socket becomes the powerbox only.
- **No peer identification.** It should record the connecting peer
  (`getpeereid`, `LOCAL_PEERPID` / `LOCAL_PEERTOKEN` on Darwin,
  `SO_PEERCRED` on Linux) for G7. This is for accountability, never as
  authority.
- **`ACK!` is sent before the request is read or validated.** It must
  never be read as success.
- **`argv[0]` is resolved via the server's `PATH` at every spawn.** It
  should be an absolute, immutable path.
- **Children inherit sigexec's stdout and stderr and every fd not marked
  close-on-exec.** On Darwin that includes fds received for concurrent
  connections.
- **Key `01` appends untrusted input to argv.** That's acceptable only with
  §6.2's rules for scripts.
