# Matrix Releasetracker

For more information, questions, or just the use of the hosted version, you can visit [#releasetracker:kittenface.studio](https://matrix.to/#/#releasetracker:kittenface.studio).

![Example image](https://i.imgur.com/iAP1rMs.png)

## Usage

Example state event for advanced tracking;

```jsonc
{
  "type": "dev.ananace.ReleaseTracker",
  "sender": "@ace:kittenface.studio",
  "content": {
    "type": "m.text", // m.notice by default
    "tracking": [
      // GitHub repositories;
      "github:r/vector-im/element-web",
      "github:r/matrix-org/synapse",

      // GitHub group;
      "github:g/netbox-community",

      // GitHub user (all starred repositories)
      "github:u/ananace",

      // GitLab(.com) repository;
      "gitlab:r/mb-saces/synatainer",
      // GitLab (self-hosted) repository;
      "gitlab://dev.funkwhale.audio/r/funkwhale/funkwhale",

      // Gitea repository;
      "gitea://git.lecygnenoir.info/r/LecygneNoir/peertube-helm",

      // Bare git repo;
      "git+https://git.zx2c4.com/wireguard-tools",
      "git+ssh://git.zx2c4.com/wireguard-tools",
      "git://git.zx2c4.com/wireguard-tools"
    ]
  },
  "state_key": "",
  "origin_server_ts": 1657845040362,
  "event_id": "$Of010lcT1D19peJ9pZFAN4vV6dYwlAXtVYg_0rGSESs",
  "room_id": "!YcpuFlnupDnkbqHuKU:example.com"
}
```

### Running

The `bin/tracker` binary will track and post updates on new GitHub releases, it requires a `releasetracker.yml` configuration file that it can read and write to.

Once installed and started, all that's necessary to - currently - run the bot is to open a conversation with it and type `!github <username>`

Example config:

```yaml
---
:backends:
- :access_token: 0000000000000000000000000000000000000000 # GitHub access token - needs the public_repo scope
  # also acceptable are a :login, :password combination - or :client_id, :client_secret for OAuth without GraphQL support
  # It's also possible to skip the authentication entirely, to run with heavily reduced limits
  :type: github
- :type: gitlab
- :type: gitea
:client:
  :hs_url: https://matrix.org
  :access_token: <token>
:database:
  # Will default to a database.db in the working-directory if missing
  #:connection_string: sqlite://database.db
```

Example systemd unit:

```ini
# ~/.config/systemd/user/matrix-releasetracker.service
[Unit]
Description=Release tracker for Matrix

[Service]
Type=simple
WorkingDirectory=/opt/matrix-releasetracker
ExecStart=/bin/bash -lc 'bundle exec bin/tracker'
Restart=on-failure

[Install]
WantedBy=default.target
```

## TODO

- ~~Store data in an actual database, not the config file~~
- ~~Track releases in separate data structures~~ - maybe partially on Matrix, map against update timestamps on each user
  - Allow requesting pre-release releases as well (Will require proper data storage)
  - Don't lose releases when multiple releases are done a short period
- Improve markdown rendering and release note splitting (optional per user)
- Implement bot-like bang commands to add/remove users and per-user configuration
- Properly handle releases on moving tags (e.g. neovim/neovim nightly)
- Handle PGP signatures better, don't just print the signature

- ~~Use GraphQL for the GitHub queries?~~ (requires an access token / username + password, as it isn't possible with OAuth apps at the moment)

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ananace/matrix_releasetracker

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
