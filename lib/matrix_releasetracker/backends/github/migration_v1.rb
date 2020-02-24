db = config.database

old_persistent_repos.each do |name, prepo|
  erepo = old_ephemeral_repos[name] || {}

  db[:tracking].insert_conflict(:update).insert(
    object: erepo[:full_name],
    backend: :github,
    type: :repository,

    name: erepo[:name] || name,
    url: erepo[:html_url],
    avatar: erepo[:avatar_url],
    next_metadata_update: erepo[:next_data_sync]
    next_update: erepo[:next_check]
  )

  next unless erepo[:latest]

  rel = erepo[:latest]

  db[:releases].insert_conflict(:update).insert(
    namespace: name,
    version: rel[:tag_name],
    backend: :github,

    name: rel[:name],
    commit_sha: rel[:sha],
    publish_date: rel[:published_at],
    release_nodes: rel[:body],
    url: rel[:html_url],
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
