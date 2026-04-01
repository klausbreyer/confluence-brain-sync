%{
  # Example: "https://your-site.atlassian.net"
  confluence_base_url: "https://your-site.atlassian.net",

  # Your Atlassian login email
  confluence_email: "you@example.com",

  # Create this token in your Atlassian account security settings
  confluence_api_token: "replace-me",

  # Relative to the directory where you run: `elixir sync_confluence.exs`
  local_sync_dir: "./export",

  # true  -> sync parent pages and all child pages
  # false -> sync only the explicitly provided parent pages
  sync_child_pages: true
}
