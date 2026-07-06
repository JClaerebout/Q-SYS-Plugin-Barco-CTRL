# Q-SYS Plugin for Barco CTRL

## Overview

The **Barco CTRL Q-SYS Plugin** integrates Barco CTRL video walls with Q-SYS. It discovers CTRL wall workplaces and compositions, recalls a composition to a selected wall, and controls wall power and brightness through each wall's Barco Wall Manager.

## Features

- Connects to Barco CTRL over HTTPS
- Authenticates with OAuth 2.0 client credentials
- Discovers up to five wall workplaces
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
| Version | 1.0.0.0 |
| Author | Jens Claerebout |
| Protocol | HTTPS REST API |
| Authentication | OAuth 2.0 client credentials / Wall Manager authentication key |

## Configuration

### Properties

| Property | Description |
| -------- | ----------- |
| `#Walls` | Number of wall pages and control sets to create (1–5) |

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

One page is generated for each configured wall. Each page displays the discovered wall information and provides composition recall, Wall Manager configuration, brightness, power, and status controls.

Walls are assigned to pages in the order returned by the Barco CTRL API.

## Communication

### Barco CTRL API

The plugin requests an access token from:

`/auth/realms/OCS/protocol/openid-connect/token`

It then uses the CTRL Operate API to:

- retrieve compositions from `/api/operate/v3/compositions?owner=all`
- retrieve walls from `/api/operate/v3/workplaces?type=Wall`
- recall content with `PUT /api/operate/v3/workplaces/{id}/content`

The access token is refreshed before it expires. Compositions are refreshed every 60 seconds.

### Barco Wall Manager API

Each configured wall authenticates through:

`POST /api/v1/auth/key`

The resulting session is used to read and set:

- `/api/v1/wall/brightness`
- `/api/v1/wall/power`

Brightness and power feedback are polled every 60 seconds.

## Installation

1. Place `Barco_CTRL.qplug` in the Q-SYS plugin directory or deploy it through Q-SYS Designer.
2. Add the plugin to the design.
3. Set `#Walls` to the required number of wall control pages.
4. On the Setup page, enter the Barco CTRL address, client ID, and client secret.
5. On each Wall page, enter the corresponding Wall Manager address and authentication key.
6. Deploy the design to the Q-SYS Core.
7. Confirm that the CTRL and Wall Manager status controls show `OK`.

## Notes

- The Q-SYS Core must be able to reach the Barco CTRL server and each Wall Manager over HTTPS.
- Valid CTRL API client credentials and Wall Manager authentication keys are required.
- Changing CTRL credentials clears the current token and reloads wall data.
- Selecting a composition immediately recalls it full-size at position `0,0` on the assigned wall.

## Known Limitations

- A maximum of five walls can be configured.
- Wall assignment follows the order returned by the CTRL API and is not manually selectable.
- Composition recall replaces the wall content with one full-size composition.
- The plugin does not provide certificate configuration or custom port settings.

## License

MIT License

## Author

Jens Claerebout
