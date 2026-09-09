%{
  confluence_base_url: "https://myosotis.atlassian.net",

  # Your Atlassian login email and API token
  confluence_email: "you@example.com",
  confluence_api_token: "replace-me",

  # Relative to the directory where you run the script. Cleared before each sync.
  # Keep trial runs separate from an existing page-based export.
  local_sync_dir: "./confluence-sync-spaces",

  # Always sync every accessible current page, including all nested subpages.
  # Each space becomes a top-level folder. Without output_dir, its key is used.
  # Plain space keys (e.g. "PED") or overview URLs also work as list entries.
  sync_targets: [
    %{
      source: "https://myosotis.atlassian.net/wiki/spaces/PED/overview",
      output_dir: "PED"
    },
    %{
      source: "https://myosotis.atlassian.net/wiki/spaces/FFP/overview",
      output_dir: "FFP"
    },
    %{
      source: "https://myosotis.atlassian.net/wiki/spaces/myoformfix/overview",
      output_dir: "myoformfix"
    },
    %{
      source:
        "https://myosotis.atlassian.net/wiki/spaces/~712020e2d192065fec4c0e90ea115757a438c4/overview?homepageId=3727524416",
      output_dir: "Privat"
    },
    %{
      source: "https://myosotis.atlassian.net/wiki/spaces/MYO/overview",
      output_dir: "MYO"
    }
  ]
}
