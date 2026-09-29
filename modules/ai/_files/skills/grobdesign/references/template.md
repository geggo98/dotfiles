# Grobdesign: <Title>

<!-- Delete every chapter without content. Fictional names only in examples. -->

**TL;DR:** <What changes and why, in one to three sentences.>

**Goals:** <...>
**Non-goals:** <...>

## 1 Context and scope (C4 L1)

Scope: <what is inside the frame>.

```mermaid
flowchart LR
  user([Customer])
  subgraph sys["Order system — scope: order handling"]
    core["Order system<br/>[software system]"]:::changed
  end
  pay["Payment provider<br/>[external]"]:::external
  user -->|"places orders"| core
  core -->|"charges, HTTPS"| pay
  classDef new fill:#d4f4dd,stroke:#2b8a3e
  classDef changed fill:#fff3bf,stroke:#e67700
  classDef external fill:#eee,stroke:#868e96
```

Legend: green = new, yellow = changed, grey = external.

## 2 Functional placement (C4 L2/L3)

Level: <domain | microservice | module | class | type class>.
Scope: <what is inside the frame>.

```mermaid
flowchart LR
  subgraph sys["Order system — scope: containers"]
    web["Web frontend<br/>[SPA]<br/>ordering UI"]:::changed
    api["Order service<br/>[REST]<br/>order lifecycle"]:::new
    db[("Order DB<br/>[PostgreSQL]")]:::unchanged
  end
  web -->|"POST /orders, JSON"| api
  api -->|"SQL"| db
  classDef new fill:#d4f4dd,stroke:#2b8a3e
  classDef changed fill:#fff3bf,stroke:#e67700
  classDef unchanged fill:#fff,stroke:#495057
```

| Component | Level | Responsible for | Deliberately not | Status |
|---|---|---|---|---|
| Order service | microservice | order lifecycle | payment | new |

## 3 Interfaces

### <Provider> → <Consumer>

| Field | Content |
|---|---|
| Technology / standard | <REST + OpenAPI \| gRPC \| AsyncAPI/Kafka \| ...> |
| Change | <new \| changed (breaking?) \| unchanged> |
| Versioning | <...> |
| Non-functional | <latency, throughput, availability, idempotency, ordering, authN/authZ, data protection> |
| Must change on both sides | <provider: ...; consumer: ...> |

## 4 Flows

### <Flow name>

- **Trigger:** <external request | timer | event | user | polling>
- **Data direction:** <A → B>
- **Activity direction:** <same | opposite: B asks A>
- **Sync / async, failure behaviour:** <...>

Polling example: activity goes from the poller to the source, data comes back.

```mermaid
sequenceDiagram
  participant T as Timer
  participant P as Status poller
  participant S as Payment provider
  T->>P: every 30 s (activity)
  P->>S: GET /payments/{id} (activity)
  S-->>P: status (data)
  P->>P: update order status
```

## 5 Cross-cutting and NFRs

<Only deviations from the norm.>

## 6 Decisions

- <Link to ADR>

## 7 Risks and open questions

- <Question — who clarifies it>
