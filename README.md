# Matrix Releasetracker

For more information, questions, or just the use of the hosted version, you can visit [#releasetracker:kittenface.studio](https://matrix.to/#/#releasetracker:kittenface.studio).

![Example image](https://i.imgur.com/iAP1rMs.png)

## Usage
The tracked repositories can be configured in multiple ways.

### Bot-command
Open a conversation with the bot and type `!github <username>`.
This would track all repositories starred by the defined user.

### State event
A more fine-grained approach is to save the tracked entities in the room state of a room you share with the bot.
Send a state event (e.g. via Element with `\devtools`) containing all the things you want to track. These can be easily updated with another state event.

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
      // GitLab(.com) group;
      "gitlab:g/mb-saces",
      // GitLab(.com) user stars; (with a token for if the tracker doesn't have one configured)
      "gitlab:access_token@u/mb-saces",

      // GitLab (self-hosted) repository;
      "gitlab://dev.funkwhale.audio/r/funkwhale/funkwhale",
      // GitLab (self-hosted) user stars; (with a token for if the tracker doesn't have one configured)
      "gitlab://access_token@git.example.com/u/user",
      "gitlab://<user>:access_token@git.example.com/u/user",

      // Gitea repository;
      "gitea://git.example.com/r/user/repository",
      // Gitea user stars; (with a token for if the tracker doesn't have one configured)
      "gitea://token@git.example.com/u/user",

      // Bare git repo;
      "git+https://user:password@git.example.com/private/repo",
      "git+https://git.zx2c4.com/wireguard-tools",
      "git+ssh://git@git.zx2c4.com/wireguard-tools",
      "git://git.zx2c4.com/wireguard-tools"
    ]
  },
  "state_key": "",
  "origin_server_ts": 1657845040362,
  "event_id": "$Of010lcT1D19peJ9pZFAN4vV6dYwlAXtVYg_0rGSESs",
  "room_id": "!YcpuFlnupDnkbqHuKU:example.com"
}
```

### Installation

The `bin/tracker` binary will track and post updates on new GitHub releases, it requires a `releasetracker.yml` configuration file that it can read and write to.

Example `releasetracker.yml` config-file:

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

A more fully featured configuration example can be seen in [releasetracker.yml.example](releasetracker.yml.example)

#### Systemd
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

#### Docker-compose
You can use the image from [Dockerhub](https://hub.docker.com/r/ananace/matrix-releasetracker).
Example `docker-compose.yml`
```yaml
version: "3.7"
services:
  matrix-release-tracker:
    restart: "unless-stopped"
    image: "ananace/matrix-releasetracker:latest"
    volumes:
      - "./releasetracker.yml:/app/releasetracker.yml"
```

## TODO

- Write a whole bunch of tests
- Expose configuration for allowed release types (lightweight tag, signed tag, pre-release, full release, etc)
- Handle multiple releases in a short period (between two ticks) more gracefully
- Implement bot-like bang commands to act on the configuration
- Handle PGP signatures better, don't just print the signature

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ananace/matrix_releasetracker

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
