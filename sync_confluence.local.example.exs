%{
  # Example: "https://myosotis.atlassian.net"
  confluence_base_url: "https://myosotis.atlassian.net",

  # Your Atlassian login email
  confluence_email: "you@example.com",

  # Create this token in your Atlassian account security settings
  confluence_api_token: "replace-me",

  # Relative to the directory where you run: `elixir sync_confluence.exs`
  local_sync_dir: "./confluence-sync",

  # true  -> sync parent pages and all child pages
  # false -> sync only the explicitly provided parent pages
  sync_child_pages: true,

  # Each target is synced into local_sync_dir/output_dir
  # type: :page  -> sync a page, optionally with child pages
  # type: :space -> sync a whole Confluence space via a space overview/homepage URL
  sync_targets: [
    %{
      type: :page,
      source: "https://myosotis.atlassian.net/wiki/spaces/Management/pages/4144889873/One+Page+Plan",
      output_dir: "strategy",
      include_children: true
    },
    %{
      type: :page,
      source: "https://myosotis.atlassian.net/wiki/spaces/Management/pages/3848568833/AK+Strategy",
      output_dir: "strategy",
      include_children: false
    },
    %{
      type: :page,
      source: "https://myosotis.atlassian.net/wiki/spaces/FFP/pages/4087349249/Platform+Strategie+Buy+Build",
      output_dir: "strategy",
      include_children: true
    },
    %{
      type: :page,
      source: "https://myosotis.atlassian.net/wiki/spaces/strategy/pages/3831857153/Company+Pivot+Strategy",
      output_dir: "strategy",
      include_children: false
    },
    %{
      type: :page,
      source: "https://myosotis.atlassian.net/wiki/spaces/PTD/pages/4179394562/Product+Operating+Model",
      output_dir: "product-operating-model",
      include_children: true
    },
    %{
      type: :page,
      source: "https://myosotis.atlassian.net/wiki/spaces/PTD/pages/4428922884/PED+Handbook",
      output_dir: "ped-handbook",
      include_children: true
    },
    %{
      type: :page,
      source: "https://myosotis.atlassian.net/wiki/spaces/PTD/pages/4361453590/Accountabilities",
      output_dir: "accountabilities",
      include_children: true
    },
    %{
      type: :space,
      source: "https://myosotis.atlassian.net/wiki/spaces/FFP/overview?homepageId=3755180424",
      output_dir: "formfix"
    }
  ]
}
