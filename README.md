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
  :users:
  - :name: ananace
    :room: '!exampleroomid:kittenface.studio'
  - :name: github
    :room: '!exampleroomid:matrix.org'
:client:
  :hs_url: https://kittenface.studio
  :access_token: <token>
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ananace/matrix_releasetracker

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
