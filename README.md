# vpn.toggle

Omarchy shell VPN toggle widget for NetworkManager L2TP connections.

## What it does

A bar widget that shows VPN connection status (connected/disconnected) and lets
you manage multiple NetworkManager L2TP VPN connections from its panel. Toggle
connections from the list, add new ones from the form, and disconnect or
connect everything with the hero button (or press `V`).

## Installation on a new PC

1. Install the plugin from the marketplace or git:
   ```sh
   omarchy plugin add https://github.com/atorres-git/vpn.toggle.git --enable
   ```
2. Ensure the plugin is enabled:
   ```sh
   omarchy plugin list | grep vpn
   ```
   If missing, enable it:
   ```sh
   omarchy plugin enable vpn.toggle
   ```
3. Add it to a bar section in `~/.config/omarchy/shell.json`:
   ```json
   "center": [
     { "id": "omarchy.indicators" },
     { "id": "omarchy.clock" },
     { "id": "omarchy.keyboard-layout" },
     { "id": "omarchy.weather" },
    { "id": "vpn.toggle" },
    { "id": "omarchy.system-update" }
   ]
   ```
4. Restart the shell:
   ```sh
   omarchy restart shell
   ```

## Configuration

No code editing needed. Open the VPN panel (left-click the bar icon). When you
have connections you'll see a list where each entry can be brought **Up** or
**Down**, **Edit**ed, or **Del**eted. Use **Add connection** (or press `A`) to
create a new one, then fill in the form:

- **Connection name** — NetworkManager L2TP connection name.
- **Server IP / gateway** — L2TP server gateway address.
- **Username**
- **Password**
- **Pre-shared key** — IPsec PSK.

Press **Save**. The widget keeps only the non-secret settings (connection
name, server IP, username) in the widget's entry in
`~/.config/omarchy/shell.json`:

```json
{
  "id": "vpn.toggle",
  "connections": [
    {
      "name": "MyVPN",
      "serverIp": "10.0.0.1",
      "username": "user"
    }
  ]
}
```

> The password and pre-shared key are **never** written to
> `~/.config/omarchy/shell.json`. They are handed to NetworkManager over a
> private pipe and stored in NetworkManager's own secret storage (the
> root-owned system connections file), which is the correct place for them.
> When editing a connection, leaving the password/PSK fields empty keeps the
> previously stored secrets.

`Save` also creates or updates the matching NetworkManager L2TP connection
(renaming it first if the connection name changed), so a fresh install only
needs this form. If you entered something wrong, use **Reset** to restore the
saved values, then re-enter them.

The widget polls `nmcli connection show` every 3 seconds to track status.

## Removal

1. Remove the widget from the bar in `~/.config/omarchy/shell.json`
   (delete the `{ "id": "vpn.toggle", ... }` entry).
2. Remove the plugin folder:
   ```sh
   rm -rf ~/.config/omarchy/plugins/vpn.toggle
   ```
3. Restart the shell:
   ```sh
   omarchy restart shell
   ```
4. Optionally remove any NetworkManager connections the widget created:
   ```sh
   nmcli connection delete "<name>"
   ```

## License

BSD-3-Clause. See [LICENSE](LICENSE).