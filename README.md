# node-log-agent

Small bootstrap script for forwarding a node's connection log to a protected
central endpoint.

## Install

Run on the node as root:

```bash
curl -fsSL https://raw.githubusercontent.com/roxelAlex/node-log-agent/main/install-log-agent.sh | sudo bash -s -- NL1
```

The installer detects the mounted source log automatically, then asks only for
the ingestion username and password. The password is entered without echoing
and stored in `/etc/node-log-agent/agent.env` with owner-only permissions.

It creates a `node-log-agent` container and leaves the application container
unchanged. Re-running the command updates only that agent.

## Check

```bash
docker logs --tail=50 node-log-agent
```

To change the node name or credentials, run the installer again.
