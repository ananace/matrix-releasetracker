# Matrix Releasetracker


## Installation

Add this line to your application's Gemfile:

```ruby
gem 'matrix_releasetracker', git: 'https://github.com/ananace/matrix_releasetracker'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install matrix_releasetracker

## Usage

The `bin/tracker` binary will track and post updates on new GitHub releases, it requires a `releasetracker.yml` configuration file that it can read and write to.

Example config:

```yaml
---
:backends:
- :access_token: 0000000000000000000000000000000000000000
  :type: github
  :users:
  - :name: ananace
    :room: '!exampleroomid:kittenface.studio'
  - :name: github
    :room: '!exampleroomid:matrix.org'
:client:
  :hs_url: https://kittenface.studio
  :access_token: <token>
```

Example systemd unit:

```ini
# ~/.config/systemd/user/matrix-releasetracker.service
[Unit]
Description=Release tracker for Matrix

[Service]
Type=simple
WorkingDirectory=/home/ace/Projects/ruby-matrix-releasetracker
ExecStart=/bin/bash -lc 'bundle exec bin/tracker'
Restart=on-failure

[Install]
WantedBy=default.target
```

## TODO

- Store data in an actual database, not the config file
- ~~Track releases in separate data structures~~ - maybe partially on Matrix, map against update timestamps on each user
  - Allow requesting pre-release releases as well (Will require proper data storage)
  - Don't lose releases when multiple releases are done a short period
- Improve markdown rendering and release note splitting (optional per user)
- Implement bot-like bang commands to add/remove users and per-user configuration
- Properly handle releases on moving tags (e.g. neovim/neovim nightly)
- Handle PGP signatures better, don't just print the signature

- Use GraphQL for the GitHub queries? (Doesn't seem to be possible with OAuth apps at the moment)

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ananace/matrix_releasetracker

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
