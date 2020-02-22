old_persistent_repos.each do |name, prepo|
  erepo = old_ephemeral_repos[name] || {}

  db[:tracking].insert_conflict(:update).insert(
    object: erepo[:full_name],
    backend: :github,
    type: :repository,

    extradata: {
      name: erepo[:name] || name,
      url: erepo[:html_url],
      avatar: erepo[:avatar_url],
    }.to_json,
    next_update: erepo[:next_data_sync]
  )

  next unless erepo[:latest]

  rel = erepo[:latest]

  db[:releases].insert_conflict(:update).insert(
    namespace: name,
    version: rel[:tag_name],
    backend: :github,

    reponame: erepo[:name] || name,
    name: rel[:name],
    commit_sha: rel[:sha],
    publish_date: rel[:published_at],
    release_nodes: rel[:body],
    repo_url: erepo[:html_url],
    release_url: rel[:html_url],
    avatar_url: erepo[:avatar_url] ? "#{erepo[:avatar_url]}&s=32" : 'https://avatars1.githubusercontent.com/u/9919?s=32&v=4',
    release_type: rel[:type]
  )
end

old_persistent_users.each do |name, puser|
  euser = old_ephemeral_users[name] || {}

  db[:tracking].insert_conflict(:update).insert(
    object: name,
    backend: :github,
    type: :user,

    extradata: {
      repos: puser[:repos]
    }.to_json,
    next_update: puser[:next_check]
  )
end
