# Q-SYS Plugin for Barco CTRL

> **VERSION 1.1.0.0 — IN DEVELOPMENT, NOT YET TESTED ON REAL SYSTEMS**
>
> Version 1.1.0.0 is under active development and has not yet been tested in Q-SYS Designer/Core or against real Barco CTRL and Wall Manager hardware. Automated checks do not establish that this version works on a real installation. This version is not ready for production use.

## Overview

The **Barco CTRL Q-SYS Plugin** integrates Barco CTRL walls and desks with Q-SYS. It discovers both workplace types and compositions, recalls a composition to a selected wall, and controls wall power and brightness through each wall's Barco Wall Manager.

## Features

- Connects to Barco CTRL over HTTPS
- Authenticates with OAuth 2.0 client credentials
- Discovers wall and desk workplaces, with up to five independently assigned pages of each type
- Displays wall name, pixel dimensions, and grid dimensions
- Retrieves available compositions and recalls them to a wall
- Controls and monitors wall brightness
- Controls and monitors wall power
- Authenticates independently with each Barco Wall Manager
- Automatically refreshes access tokens and polls device state

## Plugin Information

| Property | Value |
| -------- | ----- |
| Name | Barco CTRL |
| Version | 1.1.0.0 |
| Author | Jens Claerebout |
| Protocol | HTTPS REST API |
| Authentication | OAuth 2.0 client credentials / Wall Manager authentication key |

## Configuration

### Properties

| Property | Description |
| -------- | ----------- |
| `#Walls` | Number of wall pages and control sets to create (0–5; default 1) |
| `#Desks` | Number of desk pages to create (0–5; default 0) |

### CTRL Setup Controls

| Control | Description |
| ------- | ----------- |
| `IP` | Hostname or IP address of the Barco CTRL server |
| `ClientID` | OAuth client ID |
| `ClientSecret` | OAuth client secret |
| `Status` | CTRL API connection and authentication status |

### Per-Wall Controls

| Control | Pin | Description |
| ------- | --- | ----------- |
| `WallSelect` | UI | Select a wall workplace; assigned walls are hidden on other pages |
| `WallName` | Output | Discovered wall workplace name |
| `WallPxSize` | Output | Wall pixel dimensions |
| `WallGridSize` | Output | Wall grid dimensions |
| `Compositions` | UI | Available compositions; selecting one recalls it to the wall |
| `WallManagerIP` | UI | Hostname or IP address of the wall's Wall Manager |
| `WallManagerAuthKey` | UI | Wall Manager REST API authentication key |
| `WallManagerStatus` | Output | Wall Manager connection and authentication status |
| `WallBrightness` | Input/Output | Wall brightness from 0 to 100 |
| `WallPower` | Input/Output | Wall power state |

The plugin also exposes a hidden `code` input pin reserved for development use.

## UI Layout

### Setup Page

Configure the Barco CTRL address, client ID, and client secret, and monitor the CTRL connection status.

### Wall Pages

One page is generated for each configured wall. Each page displays an EzSVG grid based on the wall rows and columns, along with the discovered wall information and provides composition recall, Wall Manager configuration, brightness, power, and status controls.

Select the desired wall or desk from the dropdown at the top of its page. Each workplace can be assigned to only one page; the current selection remains visible on its own page. Choose `(None)` to release it. Labels include workplace IDs to distinguish duplicate names. Saved selections are restored after discovery when the workplace still exists.

### Desk Pages

Each desk page provides a `DeskSelect` dropdown, `DeskVpxSize` from `deskGeometry.sizeVpx`, and an EzSVG `DeskDiagram` showing displays at their virtual-pixel positions with connection, device and dimension labels. `DeskDisplays` retains text details internally. Desks do not support compositions. Wall Manager controls apply only to walls.

## Communication

### Barco CTRL API

The plugin requests an access token from:

`/auth/realms/OCS/protocol/openid-connect/token`

It then uses the CTRL Operate API to:

- retrieve compositions from `/api/operate/v3/compositions?owner=all`
- retrieve sources from `/api/operate/v3/sources`
- retrieve walls and desks from `/api/operate/v3/workplaces`
- recall content with `PUT /api/operate/v3/workplaces/{id}/content`

The access token is refreshed before it expires. Compositions and sources are normally refreshed every 60 seconds. Failed wall discovery temporarily shortens polling to five seconds until discovery succeeds; successful token or composition requests do not clear the discovery error.

### Barco Wall Manager API

Each configured wall authenticates through:

`POST /api/v1/auth/key`

The resulting session is used to read and set:

- `/api/v1/wall/brightness`
- `/api/v1/wall/power`

Brightness and power feedback are polled every 60 seconds.

Commands received during session authentication are retained, with repeated changes to the same control coalesced to the latest value. Pending commands survive authentication retries, but are discarded when connection settings change or the wall is disconnected.

## Installation

1. Place `Barco_CTRL.qplug` in the Q-SYS plugin directory or deploy it through Q-SYS Designer.
2. Add the plugin to the design.
3. Set `#Walls` and `#Desks` to the required number of pages.
4. On the Setup page, enter the Barco CTRL address, client ID, and client secret.
5. On each wall or desk page, select its workplace. For walls, enter the corresponding Wall Manager address and authentication key.
6. Deploy the design to the Q-SYS Core.
7. Confirm that the CTRL and Wall Manager status controls show `OK`.

## Notes

- The Q-SYS Core must be able to reach the Barco CTRL server and each Wall Manager over HTTPS.
- Valid CTRL API client credentials and Wall Manager authentication keys are required.
- Changing CTRL connection settings clears the current token, discovered data, and queued recalls. Replies from the previous connection are ignored.
- Changing a Wall Manager address or authentication key invalidates its session and starts fresh authentication. Replies from an old connection or session cannot update feedback or status.
- Selecting a composition recalls it at its native composition dimensions at position `0,0` on the assigned wall. Recalls are serialized per page; if another recall is pending, the latest selection is sent when it completes. A selection waiting for a valid CTRL token resumes after authentication succeeds.

## Known Limitations

- A maximum of five wall pages and five desk pages can be configured; discovery retains all available workplaces.
- Composition recall replaces the workplace content with one full-size composition.
- The plugin does not provide certificate configuration or custom port settings.

Changing a page assignment clears queued recalls and ignores late recall responses for the previous assignment. Changing a wall assignment also resets its Wall Manager session.

## Regression checks

Run the asynchronous state regression scenarios from the repository root with Lua 5.3 or later:

```sh
lua tests/async_state.lua
```

The harness executes the plugin with deterministic controls, timers, HTTP callbacks, and decoded JSON fixtures. It covers connection changes, stale responses, discovery recovery, and pending commands. It does not validate Q-SYS Designer/Core integration, HTTP/TLS behavior, or Barco API wire formats; those still require integration testing.

## License

MIT License

## Author

Jens Claerebout

## Contributors

- [timwalex-oss](https://github.com/timwalex-oss) — fixed asynchronous connection state handling and retention of pending wall commands ([#1](https://github.com/JClaerebout/Q-SYS-Plugin-Barco-CTRL/issues/1)).

The diagrams use the [Q-SYS EzSVG button legend API](https://help.qsys.com/q-sys_9.7/Content/Control_Scripting/Using_Lua_in_Q-Sys/EzSVG.htm). Wall grid text remains available on the existing `WallGridSize` output pin.

### Source discovery

Sources are fetched after authentication and on the composition polling cycle. The internal `sources` array preserves complete records, including type, class, audio/interactivity capabilities, streams and exclusive mode. Duplicate IDs across classes remain separate records. There are no source UI controls yet.

Failed source requests retain the last successful snapshot and record `sourcesError` for diagnostics; the next polling cycle retries. Connection changes clear source data and invalidate outstanding replies.

### Workplace content feedback

The plugin requests `GET /api/operate/v3/workplaces/{id}/content` for selected walls and desks on selection, during the 60-second polling cycle, and after a wall recall completes. Full response records are stored per page in `workplaceContentStates[index].data`, including geometry, fullscreen/window metadata and source/composition options.

EzSVG previews overlay green source windows and purple composition windows with type/title labels. Windows are clipped to the workplace canvas. Wall diagrams use physical pixels; desk diagrams use virtual pixels. Conversion requires both coordinate-space sizes from the API; windows with unsupported geometry are indicated rather than positioned using an assumed conversion.

Failed reads retain the last successful content and display a refresh error. Connection changes, selection changes and newer recalls invalidate stale replies. Empty content responses clear the overlays.

The compact UI uses 11 px text, aligned labels and consistent sections. Workplace pages place selection and the live preview first; wall pages then group composition recall and Wall Manager settings, with brightness and power together. Diagram labels shrink when necessary to fit small windows.
