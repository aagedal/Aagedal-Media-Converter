# Local agent access (4.5 development)

Agent Access is opt-in. Open **Settings → Agent Access**, turn on local MCP
access, and use **Test Connection**. The app shows setup for Claude Desktop,
Claude Code, Codex, and OpenCode. Select your client and copy its configuration
or Terminal command. Keep the app at that path after adding the server, then
restart the client.

Claude Desktop uses the displayed `mcpServers` JSON. Claude Code and Codex use
their displayed `claude mcp add` and `codex mcp add` commands. OpenCode uses the
displayed `mcp` JSON entry with `type: "local"` and the embedded helper path as
the sole `command` array item; merge it into your existing `opencode.json`
configuration. These setups register the helper embedded in the app; they do not
install FFmpeg or another runtime. The helper can open the app when it is
closed, but Agent Access must already be enabled in the app. OpenCode's
[local MCP configuration](https://opencode.ai/docs/mcp-servers/) documents the
required `type` and `command` fields.

Before asking a client to inspect or convert media, open **Settings → Agent
Access → Approved source folders** and add a folder such as Movies. The approval
also covers files in its subfolders and persists across app launches. Files
imported through the app continue to use their existing individual grants.
Choose the output folder in the app as before; source-folder approval does not
grant write access. Remove a folder from the list to revoke that folder's
MCP-specific grant for future requests. Other grants saved by app features may
still cover a file. Agent requests cannot approve a new location. If a drive is
unavailable or a grant is lost, reconnect the drive or select the location again
in the app and make a new plan. A plan lasts 15 minutes, and submission rechecks
access, source identity, and output collisions. Existing outputs are preserved.

The first agent release supports H.264, HEVC, ProRes, Proxy, Audio Only, and
Stream Copy. A client can call `list_presets`, `inspect_media`,
`plan_conversion`, `submit_conversion`, `get_job`, and `cancel_job`. Accepted jobs
continue after a client disconnects. Their status and results remain available
for 30 days; unfinished work becomes interrupted after an app restart and is not
automatically restarted. Turning Agent Access off rejects new connections while
already accepted jobs continue.

The first agent contract does not offer a timecode override. Agent conversions
disable output timecode, including Stream Copy of a source with a timecode track.
The accepted-settings inspector shows this policy. Manual and Shortcut jobs keep
their configured preserve-source or manual timecode behavior.

Enabling Agent Access makes these bounded operations available to processes in
the same logged-in user's launch session, not only to the configured MCP client.
Turn it off when you no longer need local agent access.

For release testing, the [named-client validation runbook](NAMED_CLIENT_VALIDATION.md)
defines the transcripts and app/output observations needed to verify each
client's conversion, reconnect, cancellation, and restart workflow.
