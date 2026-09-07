# auth: route-level access control

tinyauth is the single auth solution for `*.keiretsu.top` web apps (pocket-id has
been fully retired). it does **authN only** through google login and injects
identity headers (`Remote-Email`, `Remote-Groups`). the
**authZ** decision (who may reach a given app) lives on each route's
SecurityPolicy, because Envoy Gateway's `authorization` block matches on
`principal.headers` and its RBAC filter runs *after* extAuth, so it sees the
header tinyauth injected.

## the pattern

a protected route = an HTTPRoute + a SecurityPolicy with two blocks:

```yaml
extAuth:            # shared, no per-app config — just authenticates via tinyauth
  headersToExtAuth: [cookie, x-forwarded-proto, x-forwarded-for, user-agent]
  http:
    backendRefs: [{name: tinyauth, namespace: tinyauth, port: 3000}]
    path: "/api/auth/envoy?path="
    headersToBackend: [remote-user, remote-email, remote-name, remote-groups]
authorization:      # the allow-list, on the route
  defaultAction: Deny
  rules:
    - name: allow
      action: Allow
      principal:
        headers:
          - name: Remote-Email
            values: ["someone@gmail.com"]
```

cross-namespace extAuth to the tinyauth Service is allowed by the ReferenceGrant
in `tinyauth/referencegrant.yaml` — add a new app namespace to its `from` list.

live examples: `agents/agents/app/hermes-auth-securitypolicy.yaml` (per-user
dashboards) and `teaspoon/securitypolicy.yaml`.

## onboarding a new user

Two gates, in order:

1. **TinyAuth authN** — add their Google email to `TINYAUTH_OAUTH_WHITELIST` in
   `tinyauth/tinyauth.env` (and `tinyauth-killinit/tinyauth.env` if they need
   `*.killinit.cc`). Without this, Google login never yields a session and no
   downstream app ever sees `Remote-Email`. This is a GitOps commit.
2. **Per-app authZ** — then grant them the app:
   - most routes: add the email to that route's SecurityPolicy `Remote-Email`
     allow-list;
   - Bhaiya: invite via the Bhaiya admin / workspace collaborators UI (Bhaiya
     does authZ in-process; a Bhaiya invite is not Google sign-in);
   - Audiobookshelf: whitelist alone is enough (no SecurityPolicy; ABS
     auto-registers — see `docs/adr/0002-reading-stack-access-model.md`).

Removing a user means removing them from the whitelist (blocks new logins) and
from the relevant route allow-lists / app accounts (see ADR 0002 for credential
revocation caveats).

## applications that trust identity headers

Applications such as Grafana can use `Remote-Email` for automatic login. Because
that header is then a credential, the backend must also have destination-side
network policy that permits general access only from the authenticated Envoy
data plane. A ClusterIP Service by itself is not a sufficient trust boundary.

refs: [EG header/method authz](https://gateway.envoyproxy.io/docs/tasks/security/http-header-method-auth/),
[EG ext-auth](https://gateway.envoyproxy.io/docs/tasks/security/ext-auth/).
